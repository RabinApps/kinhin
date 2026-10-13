import XCTest

@testable import KinhinKit
@testable import kinhin

/// `kinhin video`: operand and flag parsing, `init` then `list`, and the usage errors that come before any container starts.
final class VideoCommandTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-video-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: repo)
    }

    func testTheOperandSkipsFlagsAndTheirValues() {
        XCTAssertEqual(VideoCommand.operand(in: ["launch", "--fast"]), "launch")
        XCTAssertEqual(VideoCommand.operand(in: ["--theme", "midnight", "launch"]), "launch")
        XCTAssertEqual(VideoCommand.operand(in: ["--dir", "/x", "--music", "off"]), nil)
        XCTAssertEqual(VideoCommand.operand(in: ["--fast", "social/vertical", "--format", "9:16"]), "social/vertical")
    }

    func testInitThenListRoundTrips() throws {
        try VideoCommand.initialize(["launch", "--dir", repo.path])
        try VideoCommand.initialize(["teaser", "--dir", repo.path])
        XCTAssertEqual(VideoProjects.list(in: repo), ["launch", "teaser"])
        XCTAssertThrowsError(try VideoCommand.initialize(["launch", "--dir", repo.path]))
    }

    func testInitWithNoNameMakesLaunch() throws {
        try VideoCommand.initialize(["--dir", repo.path])
        XCTAssertEqual(VideoProjects.list(in: repo), ["launch"])
    }

    func testOptionsCarryEveryFlag() throws {
        try VideoCommand.initialize(["launch", "--dir", repo.path])
        let options = try VideoCommand.options(
            from: [
                "launch", "--theme", "midnight", "--format", "9:16", "--captions", "all", "--caption-style", "box",
                "--music", "off", "--fast",
            ], repo: repo)
        XCTAssertEqual(options.project, "launch")
        XCTAssertEqual(options.theme, "midnight")
        XCTAssertEqual(options.format, "9:16")
        XCTAssertEqual(options.captions, "all")
        XCTAssertEqual(options.captionStyle, "box")
        XCTAssertEqual(options.music, "off")
        XCTAssertTrue(options.fast)
    }

    func testTheNameCanBeLeftOutOnlyWhenThereIsOneVideo() throws {
        XCTAssertThrowsError(try VideoCommand.options(from: [], repo: repo)) {
            XCTAssertTrue(($0 as? CLIError)?.message.contains("kinhin video init") == true)
        }
        try VideoCommand.initialize(["only", "--dir", repo.path])
        XCTAssertEqual(try VideoCommand.options(from: [], repo: repo).project, "only")
        try VideoCommand.initialize(["second", "--dir", repo.path])
        XCTAssertThrowsError(try VideoCommand.options(from: [], repo: repo)) {
            XCTAssertTrue(($0 as? CLIError)?.message.contains("only, second") == true)
        }
    }

    func testBadCaptionsValueIsAUsageError() throws {
        try VideoCommand.initialize(["launch", "--dir", repo.path])
        XCTAssertThrowsError(try VideoCommand.options(from: ["launch", "--captions", "maybe"], repo: repo)) {
            XCTAssertEqual(($0 as? CLIError)?.exit, .usage)
        }
    }

    func testBuildReportsAMissingVideoBeforeStartingAnything() async throws {
        try VideoCommand.initialize(["launch", "--dir", repo.path])
        do {
            try await VideoCommand.run(path: ["video", "build"], ["nope", "--dir", repo.path, "--runtime", "docker"])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? CLIError)?.exit, .usage)
            XCTAssertTrue(error.localizedDescription.contains("launch"), error.localizedDescription)
        }
    }

    func testBuildRefusesAnUnknownRuntime() async throws {
        try VideoCommand.initialize(["launch", "--dir", repo.path])
        do {
            try await VideoCommand.run(
                path: ["video", "build"], ["launch", "--dir", repo.path, "--runtime", "podman"])
            XCTFail("expected an error")
        } catch { XCTAssertEqual((error as? CLIError)?.exit, .usage) }
    }

    // MARK: music

    func testMusicOperandsAreEveryWordThatIsNotAFlagOrItsValue() {
        XCTAssertEqual(VideoMusicCommand.operands(in: ["calm", "piano", "--limit", "5", "--json"]), ["calm", "piano"])
        XCTAssertEqual(VideoMusicCommand.operands(in: ["--video", "launch", "3", "--volume", "0.3"]), ["3"])
        XCTAssertEqual(VideoMusicCommand.operands(in: ["--dir", "/x"]), [])
    }

    func testTheLicenseFlagIsCC0ByDefaultAndCCBYOnRequest() throws {
        XCTAssertFalse(try VideoMusicCommand.allowsAttribution([]))
        XCTAssertFalse(try VideoMusicCommand.allowsAttribution(["--license", "cc0"]))
        XCTAssertTrue(try VideoMusicCommand.allowsAttribution(["--license", "cc-by"]))
        XCTAssertThrowsError(try VideoMusicCommand.allowsAttribution(["--license", "cc-by-nc"])) {
            XCTAssertEqual(($0 as? CLIError)?.exit, .usage)
        }
    }

    func testMusicErrorsMapToExitCodes() {
        func code(_ error: MusicError) -> CLIExit? { (VideoMusicCommand.translate(error) as? CLIError)?.exit }
        XCTAssertEqual(code(.emptyQuery), .usage)
        XCTAssertEqual(code(.licenseNotAllowed(title: "t", license: "by-nc")), .usage)
        XCTAssertEqual(code(.needsVideo(["a", "b"])), .usage)
        XCTAssertEqual(code(.rateLimited(retryAfter: nil)), .runtime)
        XCTAssertEqual(code(.network("x")), .runtime)
        XCTAssertEqual(code(.downloadRefused("x")), .runtime)
    }

    func testSearchNeedsWordsAndAddNeedsATrack() async {
        for (sub, args) in [("search", ["--limit", "3"]), ("add", ["--dir", "/tmp"]), ("preview", [])] {
            do {
                try await VideoCommand.run(path: ["video", "music", sub], args)
                XCTFail("\(sub) should fail")
            } catch { XCTAssertEqual((error as? CLIError)?.exit, .usage, sub) }
        }
        do {
            try await VideoCommand.run(path: ["video", "music", "add"], ["1", "--volume", "9"])
            XCTFail("a bad volume should fail")
        } catch { XCTAssertEqual((error as? CLIError)?.exit, .usage) }
    }

    func testTheResultTableShowsTheLengthLicenseAndWhatIsBuiltIn() {
        let tracks = [
            BuiltInMusic.tracks[0],
            MusicTrack(
                origin: .openverse, id: "x", title: "A very long title that goes past the column width and then some",
                creator: "someone", license: "cc0", source: "freesound", seconds: 125),
        ]
        let table = VideoMusicCommand.table(tracks)
        XCTAssertTrue(table.contains("built in"))
        XCTAssertTrue(table.contains("2:05"))
        XCTAssertTrue(table.contains("CC0"))
        XCTAssertTrue(table.contains("…"), "a long title is cut, not wrapped")
        XCTAssertEqual(table.split(separator: "\n").count, 3)
        XCTAssertEqual(VideoMusicCommand.duration(59.6), "1:00")
        XCTAssertEqual(VideoMusicCommand.duration(nil), "")
    }

    func testMusicListNamesWhatEachVideoUses() throws {
        try VideoCommand.initialize(["launch", "--dir", repo.path])
        try VideoMusicCommand.list(["--dir", repo.path])
        let listing = VideoMusicService.list(in: repo)
        XCTAssertEqual(listing.videos.map(\.video), ["launch"])
        XCTAssertEqual(listing.videos.first?.track, "none")
        XCTAssertTrue(listing.saved.isEmpty)
    }

    // MARK: themes

    func testThemeNewThenListShowsBuiltInAndYourOwn() throws {
        try VideoThemeCommand.create(["brand", "--from", "chalk", "--dir", repo.path])
        XCTAssertEqual(VideoThemes.own(in: repo), ["brand"])
        XCTAssertThrowsError(try VideoThemeCommand.create(["brand", "--dir", repo.path])) {
            XCTAssertEqual(($0 as? CLIError)?.exit, .usage)
        }
        XCTAssertThrowsError(try VideoThemeCommand.create(["--dir", repo.path])) {
            XCTAssertEqual(($0 as? CLIError)?.exit, .usage)
        }
        XCTAssertThrowsError(try VideoThemeCommand.create(["x", "--from", "neon", "--dir", repo.path])) {
            XCTAssertEqual(($0 as? CLIError)?.exit, .usage)
        }
        try VideoThemeCommand.list(["--dir", repo.path])
    }

    func testTheFinishedVideoIsTheNewestFolderUnderOut() throws {
        let out = repo.appendingPathComponent("out")
        let older = out.appendingPathComponent("launch")
        let newer = out.appendingPathComponent("launch-4x5")
        for folder in [older, newer, out.appendingPathComponent(".work")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: older.path)
        XCTAssertEqual(VideoCommand.latestVideoFolder(in: out).lastPathComponent, "launch-4x5")
        XCTAssertEqual(
            VideoCommand.latestVideoFolder(in: repo.appendingPathComponent("nothing")).lastPathComponent, "nothing")
    }
}
