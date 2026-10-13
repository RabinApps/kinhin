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
            try await VideoCommand.run(subcommand: "build", ["nope", "--dir", repo.path, "--runtime", "docker"])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? CLIError)?.exit, .usage)
            XCTAssertTrue(error.localizedDescription.contains("launch"), error.localizedDescription)
        }
    }

    func testBuildRefusesAnUnknownRuntime() async throws {
        try VideoCommand.initialize(["launch", "--dir", repo.path])
        do {
            try await VideoCommand.run(subcommand: "build", ["launch", "--dir", repo.path, "--runtime", "podman"])
            XCTFail("expected an error")
        } catch { XCTAssertEqual((error as? CLIError)?.exit, .usage) }
    }
}
