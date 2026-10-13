import Foundation
import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport
@testable import kinhin_app

/// The "Make a Video…" sheet's model: choosing a repository, creating and building a video with live output, and adding music.
@MainActor
final class VideosModelTests: XCTestCase {
    private var repo: URL!
    private var cache: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-videos-\(UUID().uuidString)")
        repo = base.appendingPathComponent("repo")
        cache = base.appendingPathComponent("support/search.json")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    }

    override func tearDown() {
        StubProtocol.handler = nil
        try? FileManager.default.removeItem(at: repo.deletingLastPathComponent())
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = repo.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: doubles

    private struct OKShell: ShellRunning {
        func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
            ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private final class ScriptedProcess: VideoProcessRunning, Sendable {
        let exitCode: Int32
        let lines: [String]
        let onLine: @Sendable (String) -> Void
        let calls = Mutex<[[String]]>([])

        init(exitCode: Int32 = 0, lines: [String] = [], onLine: @escaping @Sendable (String) -> Void) {
            self.exitCode = exitCode
            self.lines = lines
            self.onLine = onLine
        }

        func runInteractive(_ argv: [String]) async throws -> Int32 {
            calls.withLock { $0.append(argv) }
            if argv.contains("run") { for line in lines { onLine(line) } }
            return exitCode
        }
    }

    private func model(
        exitCode: Int32 = 0, lines: [String] = [], runtimes: Set<VideoRuntime> = [.docker]
    ) -> VideosModel {
        let model = VideosModel()
        model.makeRunner = { onLine in
            VideoRunner(
                shell: OKShell(), process: ScriptedProcess(exitCode: exitCode, lines: lines, onLine: onLine),
                environment: [:], cpuCount: 4, binaries: { runtimes.contains($0) ? "/bin/\($0.rawValue)" : nil })
        }
        model.chooseFolder = { [repo] in repo }
        let session = { () -> URLSession in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StubProtocol.self]
            return URLSession(configuration: config)
        }()
        model.music = VideoMusicService(
            openverse: OpenverseClient(session: session, credentials: nil), library: MusicLibrary(session: session),
            cacheFile: cache)
        return model
    }

    /// Lets the main actor deliver the lines the runner reported from another thread.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    // MARK: repository and videos

    func testChoosingARepositoryListsItsVideosAndSelectsTheFirst() async throws {
        try write(".kinhin/videos/launch.yml", "name: a\n")
        try write(".kinhin/videos/social/vertical.yml", "name: b\n")
        let model = model()
        XCTAssertFalse(model.canBuild)
        await model.chooseRepository()
        XCTAssertEqual(model.videos, ["launch", "social/vertical"])
        XCTAssertEqual(model.selected, "launch")
        XCTAssertTrue(model.canBuild)

        model.selected = "social/vertical"
        model.reload()
        XCTAssertEqual(model.selected, "social/vertical", "reloading keeps a selection that still exists")
        try FileManager.default.removeItem(at: repo.appendingPathComponent(".kinhin/videos/social"))
        model.reload()
        XCTAssertEqual(model.selected, "launch")
    }

    func testCancellingTheFolderPickerChangesNothing() async {
        let model = model()
        model.chooseFolder = { nil }
        await model.chooseRepository()
        XCTAssertNil(model.repository)
        XCTAssertFalse(model.canBuild)
    }

    func testCreatingAVideoWritesTheStarterAndSelectsIt() async throws {
        let model = model()
        await model.chooseRepository()
        model.newVideoName = "teaser"
        model.createVideo()
        XCTAssertEqual(model.videos, ["teaser"])
        XCTAssertEqual(model.selected, "teaser")
        XCTAssertEqual(model.newVideoName, "")
        XCTAssertNil(model.message)

        model.newVideoName = "teaser"
        model.createVideo()
        XCTAssertTrue(model.message?.contains("will not overwrite") == true, "\(String(describing: model.message))")

        model.message = nil
        model.newVideoName = "../escape"
        model.createVideo()
        XCTAssertNotNil(model.message)
        XCTAssertEqual(model.videos, ["teaser"])

        model.newVideoName = ""
        model.createVideo()
        XCTAssertEqual(model.videos, ["launch", "teaser"], "an empty name makes launch")
    }

    // MARK: build

    func testABuildShowsItsOutputAndEndsSucceededWithTheOutputFolder() async throws {
        try write(".kinhin/videos/launch.yml", "name: a\n")
        let model = model(lines: ["==> voice-over", "wrote out/launch.mp4"])
        await model.chooseRepository()
        var options = VideoBuildOptions(project: "launch")
        options.fast = true
        await model.run(options: options, repository: repo)
        await settle()
        XCTAssertEqual(model.phase, .succeeded)
        XCTAssertEqual(model.outputDirectory?.path, repo.appendingPathComponent(".kinhin/videos/out").path)
        XCTAssertEqual(
            model.log.first, "==> launch: docker, image ghcr.io/rabinapps/kinhin-video:\(kinhinVersion.current)")
        XCTAssertTrue(model.log.contains("wrote out/launch.mp4"), "\(model.log)")
    }

    func testAFailedBuildSaysSoAndKeepsTheLog() async throws {
        try write(".kinhin/videos/launch.yml", "name: a\n")
        let model = model(exitCode: 3, lines: ["scene 1 has no id"])
        await model.chooseRepository()
        await model.run(options: VideoBuildOptions(project: "launch"), repository: repo)
        await settle()
        guard case .failed(let why) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertTrue(why.contains("3"), why)
        XCTAssertNil(model.outputDirectory)
        XCTAssertTrue(model.log.contains("scene 1 has no id"))
    }

    func testNoContainerRuntimeIsExplainedNotCrashed() async throws {
        try write(".kinhin/videos/launch.yml", "name: a\n")
        let model = model(runtimes: [])
        await model.chooseRepository()
        await model.run(options: VideoBuildOptions(project: "launch"), repository: repo)
        guard case .failed(let why) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertTrue(why.contains("container"), why)
    }

    func testBuildStartsOnlyWithARepositoryAndAVideo() async throws {
        let model = model()
        model.build()
        XCTAssertEqual(model.phase, .idle, "no repository: nothing starts")
        try write(".kinhin/videos/launch.yml", "name: a\n")
        await model.chooseRepository()
        model.build()
        XCTAssertTrue(model.isBuilding)
        XCTAssertFalse(model.canBuild, "a second build cannot start while one runs")
        model.cancelBuild()
        for _ in 0..<50 where model.isBuilding { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isBuilding)
    }

    func testTheLogKeepsOnlyTheLastLines() {
        let model = model()
        for i in 0..<(VideosModel.logLimit + 50) { model.append("line \(i)") }
        XCTAssertEqual(model.log.count, VideosModel.logLimit)
        XCTAssertEqual(model.log.last, "line \(VideosModel.logLimit + 49)")
        XCTAssertEqual(model.log.first, "line 50")
    }

    // MARK: music

    nonisolated private static let id1 = "2f5d351d-a1de-41d9-ba70-c73ba285c875"

    nonisolated private static func result(license: String = "cc0") -> String {
        """
        {"id":"\(id1)","title":"Lofi Loop","creator":"holizna","license":"\(license)","license_version":"1.0",
         "source":"freesound","url":"https://cdn.example.com/a.mp3","filetype":"mp3","duration":40000,"filesize":2048,"mature":false}
        """
    }

    private func stubLibrary() {
        StubProtocol.handler = { request in
            if request.url?.host == "api.openverse.org" {
                let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "page" }?.value
                return (200, Data("{\"results\":[\(page == "1" ? Self.result() : "")]}".utf8), [:])
            }
            return (200, Data(repeating: 7, count: 2048), [:])
        }
    }

    func testSearchingListsResultsAndAddingSetsMusicInTheSelectedVideo() async throws {
        try write(".kinhin/videos/launch.yml", "# keep me\nname: a\nscenes: []\n")
        stubLibrary()
        let model = model()
        await model.chooseRepository()
        model.musicQuery = "lofi"
        await model.searchMusic()
        XCTAssertEqual(model.musicResults.map(\.title), ["Lofi Loop"])

        await model.addMusic(at: 0)
        XCTAssertTrue(model.musicNotice?.contains("Added") == true, "\(String(describing: model.musicNotice))")
        let yaml = try String(contentsOf: repo.appendingPathComponent(".kinhin/videos/launch.yml"), encoding: .utf8)
        XCTAssertEqual(
            yaml, "# keep me\nname: a\nmusic:\n  track: \".kinhin/videos/music/lofi-loop.mp3\"\nscenes: []\n")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repo.appendingPathComponent(".kinhin/videos/music/lofi-loop.mp3").path))
    }

    func testAnEmptyQueryDoesNothingAndALibraryErrorIsShown() async {
        stubLibrary()
        let model = model()
        await model.searchMusic()
        XCTAssertTrue(model.musicResults.isEmpty)
        XCTAssertNil(model.musicNotice)

        StubProtocol.handler = { _ in (429, Data(), [:]) }
        model.musicQuery = "trap drums"
        await model.searchMusic()
        XCTAssertTrue(model.musicResults.isEmpty)
        XCTAssertTrue(model.musicNotice?.contains("rate limiting") == true, "\(String(describing: model.musicNotice))")
    }

    func testAddingNeedsAVideoAndAResultAndRefusesALicenseThatIsNotReusable() async throws {
        stubLibrary()
        let model = model()
        await model.addMusic(at: 0)  // no repository, no results: nothing happens
        XCTAssertNil(model.musicNotice)

        try write(".kinhin/videos/launch.yml", "name: a\n")
        await model.chooseRepository()
        model.musicQuery = "lofi"
        await model.searchMusic()
        await model.addMusic(at: 5)  // out of range
        XCTAssertFalse(model.addingMusic)

        StubProtocol.handler = { request in
            request.url?.host == "api.openverse.org"
                ? (200, Data("{\"results\":[\(Self.result(license: "by-nc"))]}".utf8), [:])
                : (200, Data(repeating: 7, count: 8), [:])
        }
        model.musicQuery = "lofi nc"
        await model.searchMusic()
        await model.addMusic(at: 0)
        // The search asks the library for reusable licenses only, but a stand-in that ignores that must still be refused.
        XCTAssertTrue(
            model.musicNotice?.contains("does not put in a video") == true, "\(String(describing: model.musicNotice))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".kinhin/videos/music").path))
    }
}
