import CryptoKit
import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// `kinhin video music`: the Openverse client, the license gate, searching and adding with a stubbed network, the config edit
/// that keeps the user's comments, and what `list` reports.
final class VideoMusicTests: XCTestCase {
    private var repo: URL!
    private var cache: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-music-\(UUID().uuidString)")
        repo = base.appendingPathComponent("repo")
        cache = base.appendingPathComponent("support/search.json")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    }

    override func tearDown() {
        StubProtocol.handler = nil
        try? FileManager.default.removeItem(at: repo.deletingLastPathComponent())
    }

    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    private func service() -> VideoMusicService {
        VideoMusicService(
            openverse: OpenverseClient(session: session), library: MusicLibrary(session: session), cacheFile: cache)
    }

    private static let id1 = "2f5d351d-a1de-41d9-ba70-c73ba285c875"
    private static let id2 = "ba4670ee-0445-4743-b936-79db58f51c17"
    private static let audio = Data(repeating: 7, count: 2048)

    private static func item(
        _ id: String, title: String = "Lofi Loop", license: String = "cc0", ms: Int = 40_000,
        url: String? = "https://cdn.example.com/a.mp3", type: String = "mp3", mature: Bool = false, size: Int = 2048
    ) -> String {
        let file = url.map { "\"\($0)\"" } ?? "null"
        return """
            {"id":"\(id)","title":"\(title)","creator":"holizna","license":"\(license)","license_version":"1.0",
             "license_url":"https://creativecommons.org/publicdomain/zero/1.0/","source":"freesound",
             "foreign_landing_url":"https://freesound.org/s/1","url":\(file),"filetype":"\(type)","duration":\(ms),
             "filesize":\(size),"attribution":"\\"\(title)\\" by holizna is marked with CC0 1.0.","mature":\(mature)}
            """
    }

    private static func page(_ items: [String]) -> Data {
        Data("{\"result_count\":\(items.count),\"results\":[\(items.joined(separator: ","))]}".utf8)
    }

    /// The answer for page 1; later pages are empty, as a search with few matches would be.
    private static func firstPageOnly(_ request: URLRequest, _ items: [String]) -> Data {
        let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first {
            $0.name == "page"
        }?.value
        return Self.page(page == "1" || page == nil ? items : [])
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = repo.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: client

    func testSearchAsksForTheRightThingAndDecodesTheAnswer() async throws {
        let seen = Mutex<(path: String, query: [String: String], agent: String)>(("", [:], ""))
        StubProtocol.handler = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            seen.withLock {
                $0 = (
                    request.url!.path, Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }),
                    request.value(forHTTPHeaderField: "User-Agent") ?? ""
                )
            }
            return (
                200,
                Self.page([
                    Self.item(Self.id1), Self.item(Self.id2, url: nil), Self.item("3", mature: true),
                    Self.item("4", license: ""),
                ]), [:]
            )
        }
        let tracks = try await OpenverseClient(session: session).search(query: "lofi piano", licenses: ["cc0", "pdm"])
        let request = seen.withLock { $0 }
        XCTAssertEqual(request.path, "/v1/audio")
        XCTAssertEqual(request.query["q"], "lofi piano")
        XCTAssertEqual(request.query["license"], "cc0,pdm")
        XCTAssertEqual(request.query["page_size"], "20", "the anonymous maximum")
        XCTAssertEqual(request.query["page"], "1")
        XCTAssertEqual(request.query["mature"], "false")
        XCTAssertTrue(request.agent.hasPrefix("kinhin/"))
        XCTAssertEqual(tracks.count, 1, "a result with no file, a mature one and one with no license are dropped")
        let track = try XCTUnwrap(tracks.first)
        XCTAssertEqual(track.id, Self.id1)
        XCTAssertEqual(track.seconds, 40)
        XCTAssertEqual(track.fileType, "mp3")
        XCTAssertEqual(track.license, "cc0")
        XCTAssertEqual(track.origin, .openverse)
    }

    func testErrorsAreExplained() async {
        StubProtocol.handler = { _ in (429, Data(), ["Retry-After": "30"]) }
        let client = OpenverseClient(session: session)
        do {
            _ = try await client.search(query: "x", licenses: ["cc0"])
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? MusicError, .rateLimited(retryAfter: 30)) }

        StubProtocol.handler = { _ in (401, Data(#"{"detail":"page_size may not exceed 20"}"#.utf8), [:]) }
        do {
            _ = try await client.search(query: "x", licenses: ["cc0"])
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? MusicError, .network("page_size may not exceed 20")) }

        StubProtocol.handler = nil  // the stub then fails every request, like no network
        do {
            _ = try await client.search(query: "x", licenses: ["cc0"])
            XCTFail("expected an error")
        } catch {
            guard case MusicError.network = error else { return XCTFail("\(error)") }
        }
    }

    func testDetailNeedsAnIdThatLooksLikeOne() async throws {
        let client = OpenverseClient(session: session)
        do {
            _ = try await client.detail(id: "../../etc")
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? MusicError, .notFound("../../etc")) }
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/audio/\(Self.id1)")
            return (200, Data(Self.item(Self.id1).utf8), [:])
        }
        let track = try await client.detail(id: Self.id1)
        XCTAssertEqual(track.id, Self.id1)
    }

    // MARK: license

    func testOnlyReusableLicensesPassAndCCBYNeedsAskingForAndCredit() {
        for code in ["cc0", "pdm", "CC0"] { XCTAssertTrue(MusicLicense.isAllowed(code, allowAttribution: false), code) }
        XCTAssertFalse(MusicLicense.isAllowed("by", allowAttribution: false))
        XCTAssertTrue(MusicLicense.isAllowed("by", allowAttribution: true))
        for code in ["by-nc", "by-sa", "by-nd", "by-nc-sa", "", "all-rights-reserved"] {
            XCTAssertFalse(MusicLicense.isAllowed(code, allowAttribution: true), code)
        }
        XCTAssertTrue(MusicLicense.needsCredit("by"))
        XCTAssertFalse(MusicLicense.needsCredit("cc0"))
        XCTAssertEqual(MusicLicense.searchCodes(allowAttribution: false), ["cc0", "pdm"])
    }

    func testTheBuiltInTrackMatchesTheCatalogTheImageShips() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("video/music/catalog.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let tracks = try XCTUnwrap(json?["tracks"] as? [String: [String: Any]])
        XCTAssertEqual(Set(tracks.keys), Set(BuiltInMusic.tracks.map(\.id)))
        for built in BuiltInMusic.tracks {
            let entry = try XCTUnwrap(tracks[built.id])
            XCTAssertEqual(entry["title"] as? String, built.title)
            XCTAssertEqual(entry["artist"] as? String, built.creator)
            XCTAssertEqual(entry["page"] as? String, built.landingURL)
            XCTAssertEqual((entry["license"] as? String)?.lowercased().hasPrefix(built.license), true)
        }
        XCTAssertEqual(BuiltInMusic.matching("calm piano").map(\.id), ["first-light-particles"])
        XCTAssertTrue(BuiltInMusic.matching("trap drums").isEmpty)
    }

    // MARK: library

    func testSlugsAreSafeAndDropAFileExtensionFromTheTitle() {
        XCTAssertEqual(MusicLibrary.slug("Calm Piano (loop) #2"), "calm-piano-loop-2")
        XCTAssertEqual(MusicLibrary.slug("Lofi Jazz Organ Loop 95 BPM.wav"), "lofi-jazz-organ-loop-95-bpm")
        XCTAssertEqual(MusicLibrary.slug("../../etc/passwd"), "etc-passwd")
        XCTAssertEqual(MusicLibrary.slug("日本語"), "track")
        XCTAssertEqual(MusicLibrary.slug(String(repeating: "a", count: 200)).count, 48)
    }

    func testRedirectsMustStayOnHTTPS() {
        let guardDelegate = HTTPSOnlyRedirects()
        let response = HTTPURLResponse(
            url: URL(string: "https://a.example/x")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let results = Mutex<[Bool]>([])
        for url in ["https://b.example/y", "http://b.example/y"] {
            guardDelegate.urlSession(
                session, task: session.dataTask(with: URL(string: "https://a.example/x")!),
                willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: url)!)
            ) { next in results.withLock { $0.append(next != nil) } }
        }
        XCTAssertEqual(results.withLock { $0 }, [true, false])
    }

    // MARK: search and add

    private func searchThenAdd(
        _ items: [String], reference: String = "1", video: String? = nil, volume: Double? = nil,
        allowAttribution: Bool = false
    ) async throws -> MusicAddResult {
        StubProtocol.handler = { request in
            request.url?.host == "api.openverse.org"
                ? (200, Self.firstPageOnly(request, items), [:]) : (200, Self.audio, [:])
        }
        var options = MusicSearchOptions(query: "lofi")
        options.allowAttribution = allowAttribution
        _ = try await service().search(options)
        return try await service().add(
            reference: reference, repo: repo, video: video, volume: volume, allowAttribution: allowAttribution)
    }

    func testSearchFiltersByLengthAndFormatPutsBuiltInsFirstAndRemembersTheRows() async throws {
        StubProtocol.handler = { _ in
            (
                200,
                Self.page([
                    Self.item(Self.id1, title: "Short blip", ms: 2_000), Self.item(Self.id2, title: "Calm piano loop"),
                    Self.item("5b3a4c5d-0000-4000-8000-000000000001", title: "Odd format", type: "ogx"),
                ]), [:]
            )
        }
        let outcome = try await service().search(MusicSearchOptions(query: "calm piano"))
        XCTAssertNil(outcome.warning)
        XCTAssertEqual(outcome.tracks.map(\.title), ["First Light Particles", "Calm piano loop"])
        let first = try await service().resolve("1")
        let second = try await service().resolve("2")
        XCTAssertEqual(first.id, "first-light-particles")
        XCTAssertEqual(second.id, Self.id2)
        do {
            _ = try await service().resolve("9")
            XCTFail("expected an error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("had 2 results"), error.localizedDescription) }
    }

    func testBuiltInMatchesStillShowWhenTheLibraryIsUnreachable() async throws {
        StubProtocol.handler = { _ in (429, Data(), [:]) }
        let outcome = try await service().search(MusicSearchOptions(query: "calm piano"))
        XCTAssertEqual(outcome.tracks.map(\.id), ["first-light-particles"])
        XCTAssertNotNil(outcome.warning)

        do {
            _ = try await service().search(MusicSearchOptions(query: "trap drums"))
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? MusicError, .rateLimited(retryAfter: nil)) }
    }

    func testANumberNeedsASearchFirst() async {
        do {
            _ = try await service().resolve("1")
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? MusicError, .noSearchYet("1")) }
    }

    func testAddDownloadsRecordsProvenanceAndEditsTheConfigKeepingItsComments() async throws {
        try write(
            ".kinhin/videos/launch.yml",
            "# my launch video\nname: Launch   # keep this\ntheme: paper\n# music: { track: x }\nscenes:\n  - id: a\n")
        let result = try await searchThenAdd([Self.item(Self.id1)], volume: 0.3)
        XCTAssertEqual(result.video, "launch")
        XCTAssertTrue(result.edited)
        let saved = try XCTUnwrap(result.savedFile)
        XCTAssertEqual(saved.lastPathComponent, "lofi-loop.mp3")
        XCTAssertEqual(try Data(contentsOf: saved), Self.audio)

        let yaml = try String(contentsOf: repo.appendingPathComponent(".kinhin/videos/launch.yml"), encoding: .utf8)
        XCTAssertEqual(
            yaml,
            "# my launch video\nname: Launch   # keep this\ntheme: paper\n# music: { track: x }\n"
                + "music:\n  track: \".kinhin/videos/music/lofi-loop.mp3\"\n  volume: 0.3\nscenes:\n  - id: a\n")

        let sidecar = try JSONDecoder().decode(MusicSidecar.self, from: Data(contentsOf: try XCTUnwrap(result.sidecar)))
        XCTAssertEqual(sidecar.sha256, SHA256.hash(data: Self.audio).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(sidecar.license, "cc0")
        XCTAssertEqual(sidecar.source, "freesound")
        XCTAssertEqual(sidecar.openverseID, Self.id1)
        XCTAssertNil(sidecar.credit)
        XCTAssertNil(result.credit)

        let listing = VideoMusicService.list(in: repo)
        XCTAssertEqual(
            listing.videos, [VideoMusicUse(video: "launch", track: ".kinhin/videos/music/lofi-loop.mp3", volume: 0.3)])
        XCTAssertEqual(listing.saved.map(\.usedBy), [["launch"]])
        XCTAssertEqual(VideoProjects.list(in: repo), ["launch"], "the saved .json files are not videos")
    }

    func testTwoTracksWithTheSameTitleGetDifferentFiles() async throws {
        try write(".kinhin/videos/launch.yml", "name: x\n")
        _ = try await searchThenAdd([Self.item(Self.id1)])
        let second = try await searchThenAdd([Self.item(Self.id2)])
        XCTAssertEqual(second.savedFile?.lastPathComponent, "lofi-loop-2.mp3")
    }

    func testAnUnusedTrackIsReportedAsUnused() async throws {
        try write(".kinhin/videos/launch.yml", "name: x\n")
        _ = try await searchThenAdd([Self.item(Self.id1)])
        try write(".kinhin/videos/launch.yml", "name: x\nmusic: false\n")
        let listing = VideoMusicService.list(in: repo)
        XCTAssertEqual(listing.videos.map(\.track), ["off"])
        XCTAssertEqual(listing.saved.map(\.usedBy), [[]])
    }

    func testALicenseThatIsNotReusableIsRefusedBeforeAnythingIsDownloaded() async throws {
        try write(".kinhin/videos/launch.yml", "name: x\n")
        StubProtocol.handler = { _ in (200, Data(Self.item(Self.id1, license: "by-nc").utf8), [:]) }
        do {
            _ = try await service().add(
                reference: Self.id1, repo: repo, video: nil, volume: nil, allowAttribution: true)
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? MusicError, .licenseNotAllowed(title: "Lofi Loop", license: "by-nc")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: MusicLibrary.directory(in: repo).path))
    }

    func testCCBYIsRefusedUnlessAskedForAndThenCarriesItsCredit() async throws {
        try write(".kinhin/videos/launch.yml", "name: x\nscenes: []\n")
        do {
            _ = try await searchThenAdd([Self.item(Self.id1, license: "by")])
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? MusicError, .licenseNotAllowed(title: "Lofi Loop", license: "by")) }

        let result = try await searchThenAdd([Self.item(Self.id1, license: "by")], allowAttribution: true)
        let credit = try XCTUnwrap(result.credit)
        XCTAssertTrue(credit.contains("holizna"), credit)
        let yaml = try String(contentsOf: repo.appendingPathComponent(".kinhin/videos/launch.yml"), encoding: .utf8)
        XCTAssertTrue(yaml.contains("credit: \""), yaml)
    }

    func testTheVideoIsChosenBeforeDownloading() async throws {
        StubProtocol.handler = { request in
            request.url?.host == "api.openverse.org"
                ? (200, Self.page([Self.item(Self.id1)]), [:]) : (200, Self.audio, [:])
        }
        _ = try await service().search(MusicSearchOptions(query: "lofi"))

        do {
            _ = try await service().add(reference: "1", repo: repo, video: nil, volume: nil, allowAttribution: false)
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? MusicError, .noVideos) }

        try write(".kinhin/videos/a.yml", "name: a\n")
        try write(".kinhin/videos/b.yml", "name: b\n")
        do {
            _ = try await service().add(reference: "1", repo: repo, video: nil, volume: nil, allowAttribution: false)
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? MusicError, .needsVideo(["a", "b"])) }
        do {
            _ = try await service().add(reference: "1", repo: repo, video: "nope", volume: nil, allowAttribution: false)
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? VideoError, .unknownProject(name: "nope", available: ["a", "b"])) }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: MusicLibrary.directory(in: repo).path), "nothing was downloaded")

        let chosen = try await service().add(
            reference: "1", repo: repo, video: "b", volume: nil, allowAttribution: false)
        XCTAssertEqual(chosen.video, "b")
        let a = try String(contentsOf: repo.appendingPathComponent(".kinhin/videos/a.yml"), encoding: .utf8)
        XCTAssertEqual(a, "name: a\n", "the other video is untouched")
    }

    func testABuiltInTrackIsNamedInTheConfigAndDownloadsNothing() async throws {
        try write(".kinhin/videos/launch.yml", "name: x\nmusic: false\nscenes: []\n")
        StubProtocol.handler = { _ in
            XCTFail("a built-in track needs no network")
            return (500, Data(), [:])
        }
        let result = try await service().add(
            reference: "first-light-particles", repo: repo, video: nil, volume: nil, allowAttribution: false)
        XCTAssertNil(result.savedFile)
        let yaml = try String(contentsOf: repo.appendingPathComponent(".kinhin/videos/launch.yml"), encoding: .utf8)
        XCTAssertEqual(yaml, "name: x\nmusic:\n  track: \"first-light-particles\"\nscenes: []\n")
    }

    func testAJSONConfigIsNotRewrittenAndTheSnippetIsReturned() async throws {
        try write(".kinhin/videos/launch.json", #"{"name": "x", "scenes": []}"#)
        let result = try await searchThenAdd([Self.item(Self.id1)])
        XCTAssertFalse(result.edited)
        XCTAssertTrue(result.snippet.contains("track: \".kinhin/videos/music/lofi-loop.mp3\""))
        let json = try String(contentsOf: repo.appendingPathComponent(".kinhin/videos/launch.json"), encoding: .utf8)
        XCTAssertEqual(json, #"{"name": "x", "scenes": []}"#)
    }

    func testDownloadsThatAreNotSafeAreRefused() async throws {
        try write(".kinhin/videos/launch.yml", "name: x\n")
        let cases: [(String, String)] = [
            (Self.item(Self.id1, url: "http://cdn.example.com/a.mp3"), "not https"),
            (Self.item(Self.id1, size: MusicLibrary.maxBytes + 1), "limit"),
            (Self.item(Self.id1, url: "https://cdn.example.com/a.exe", type: "exe"), "format"),
        ]
        for (json, expected) in cases {
            // Asked for by id, so the search's own filters do not hide the case.
            StubProtocol.handler = { _ in (200, Data(json.utf8), [:]) }
            do {
                _ = try await service().add(
                    reference: Self.id1, repo: repo, video: nil, volume: nil, allowAttribution: false)
                XCTFail("expected an error for \(expected)")
            } catch {
                XCTAssertTrue(
                    error.localizedDescription.contains(expected), "\(expected): \(error.localizedDescription)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: MusicLibrary.directory(in: repo).path))
    }

    // MARK: the config editor

    func testSetMusicReplacesEveryShapeInPlace() {
        let cases: [(String, String)] = [
            ("a: 1\nmusic: false\nb: 2\n", "a: 1\nmusic:\n  track: \"t\"\nb: 2\n"),
            ("a: 1\nmusic: first-light-particles\nb: 2\n", "a: 1\nmusic:\n  track: \"t\"\nb: 2\n"),
            ("a: 1\nmusic: { track: x, volume: 1 }   # old\nb: 2\n", "a: 1\nmusic:\n  track: \"t\"\nb: 2\n"),
            (
                "a: 1\nmusic:\n  track: x\n  volume: 0.5\n\n# next\nb: 2\n",
                "a: 1\nmusic:\n  track: \"t\"\n\n# next\nb: 2\n"
            ),
            ("music:\n  track: x\n", "music:\n  track: \"t\"\n"),
        ]
        for (before, after) in cases {
            let result = VideoConfigEditor.setMusic(in: before, track: "t")
            XCTAssertEqual(result.text, after, before)
            XCTAssertTrue(result.replaced)
        }
    }

    func testSetMusicInsertsBeforeScenesOrAtTheEnd() {
        XCTAssertEqual(
            VideoConfigEditor.setMusic(in: "name: x\nscenes:\n  - id: a\n", track: "t", volume: 1).text,
            "name: x\nmusic:\n  track: \"t\"\n  volume: 1\nscenes:\n  - id: a\n")
        XCTAssertEqual(
            VideoConfigEditor.setMusic(in: "name: x", track: "t").text, "name: x\nmusic:\n  track: \"t\"\n")
        XCTAssertEqual(VideoConfigEditor.setMusic(in: "", track: "t").text, "music:\n  track: \"t\"\n")
        XCTAssertFalse(VideoConfigEditor.setMusic(in: "name: x\n", track: "t").replaced)
    }

    func testSetMusicKeepsWindowsLineEndingsAndQuotesTheCredit() {
        let result = VideoConfigEditor.setMusic(
            in: "name: x\r\nmusic: false\r\nscenes: []\r\n", track: "a b", credit: "\"T\" by \"A\" \\ ok")
        XCTAssertEqual(
            result.text,
            "name: x\r\nmusic:\r\n  track: \"a b\"\r\n  credit: \"\\\"T\\\" by \\\"A\\\" \\\\ ok\"\r\nscenes: []\r\n")
    }

    func testAKeyThatOnlyStartsWithMusicIsNotTheMusicKey() {
        let text = "musical: 1\nmusic_x: 2\nscenes: []\n"
        let result = VideoConfigEditor.setMusic(in: text, track: "t")
        XCTAssertFalse(result.replaced)
        XCTAssertEqual(result.text, "musical: 1\nmusic_x: 2\nmusic:\n  track: \"t\"\nscenes: []\n")
    }

    func testDescribeReadsEveryShapeOfTheMusicSetting() {
        XCTAssertEqual(VideoMusicService.describe(music: nil, video: "v").track, "none")
        XCTAssertEqual(VideoMusicService.describe(music: false, video: "v").track, "off")
        XCTAssertEqual(VideoMusicService.describe(music: "t", video: "v").track, "t")
        XCTAssertEqual(
            VideoMusicService.describe(music: ["track": "t", "volume": 1], video: "v"),
            VideoMusicUse(video: "v", track: "t", volume: 1))
        XCTAssertEqual(VideoMusicService.describe(music: ["track": "t", "enabled": false], video: "v").track, "off")
    }
}
