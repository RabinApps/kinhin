import XCTest
import KinhinKit
@testable import kinhin

// The route-editing subcommands must behave exactly like the pane's
// add/remove: same editor, same validation gate, same upsert semantics.
// The command core is called directly with a scratch config URL so no test
// touches the developer's real config (and `fail`/exit stays out of tests).
@MainActor
final class RuntimesRouteCommandTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        scratch = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: FileManager.default.temporaryDirectory, create: true)
            .appendingPathComponent("kinhin-route-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    private var scratch: URL!

    private var configURL: URL { scratch.appendingPathComponent("config.yaml") }

    private func installConfig(_ yaml: String) throws {
        try yaml.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func onDiskText() throws -> String {
        try String(contentsOf: configURL, encoding: .utf8)
    }

    /// Read the on-disk runtimes section back through the editor's parser.
    private func routedSection() throws -> kinhinConfig.RuntimeConfig? {
        try RuntimesConfigEditor.parsed(from: onDiskText())
    }

    // A minimal-but-valid config, mirroring the starter template, with the
    // container section configured (routes to appleContainer are rejected by
    // engine validation without an image).
    private let baseConfig = """
    # kinhin configuration
    repo: "acme/ios-app"

    labels: ["self-hosted", "macos", "arm64"]

    max_runners: 4

    vm:
      cpu: 4
      memory_gb: 8

    image: "tahoe-base"

    reserve:
      cpu: 2
      memory_gb: 4

    poll_interval: 30

    container:
      image: "kinhin-ci-linux"
      cpus: 2
      memory_gb: 4
    """

    private func runRoute(_ tail: [String]) async throws {
        // The core receives the args *after* `runtimes route`.
        try await RuntimesCommand.route(tail, configURL: configURL, notifyDaemon: false)
    }

    // MARK: add

    func testAddCreatesSectionWhenAbsentAndPersistsRoute() async throws {
        try installConfig(baseConfig)
        try await runRoute(["add", "acme/api", "appleContainer"])

        let rc = try XCTUnwrap(try routedSection(), "runtimes: section must be created")
        XCTAssertEqual(rc.routes.count, 1)
        XCTAssertEqual(rc.routes.first?.pattern, "acme/api")
        XCTAssertEqual(rc.routes.first?.runtime, "appleContainer")
        XCTAssertEqual(rc.defaultRuntime, "tart", "section creation uses the default runtime")
    }

    func testAddPersistsCommentAboveSection() async throws {
        try installConfig(baseConfig + "\n# Routing: Linux repos to containers\n")
        try await runRoute(["add", "acme/api", "appleContainer"])

        let text = try onDiskText()
        XCTAssertTrue(text.contains("# Routing: Linux repos to containers"), "comments around the section survive")
        XCTAssertTrue(text.contains("runtimes:"))
    }

    func testAddWorkflowRouteIsStoredVerbatim() async throws {
        try installConfig(baseConfig)
        try await runRoute(["add", "acme/web@Nightly", "appleContainer"])

        let rc = try XCTUnwrap(try routedSection())
        XCTAssertEqual(rc.routes.first?.pattern, "acme/web@Nightly")
    }

    func testAddRejectsDuplicatePattern() async throws {
        try installConfig(baseConfig)
        try await runRoute(["add", "acme/api", "appleContainer"])
        let first = try routedSection()

        do {
            try await runRoute(["add", "acme/api", "tart"])
            XCTFail("duplicate add must throw")
        } catch let error as RuntimesCommand.RouteError {
            XCTAssertTrue(error.message.contains("already exists"))
        }
        let second = try routedSection()

        let before = try XCTUnwrap(first?.routes.first)
        let after = try XCTUnwrap(second?.routes.first)
        XCTAssertEqual(before.pattern, after.pattern)
        XCTAssertEqual(before.runtime, after.runtime, "duplicate add must not change the file")
        XCTAssertEqual(second?.routes.count, 1)
    }

    func testAddUnknownRuntimeLeavesFileUntouched() async throws {
        try installConfig(baseConfig)
        let original = try onDiskText()

        do {
            try await runRoute(["add", "acme/api", "kubernetes"])
            XCTFail("unknown runtime must throw")
        } catch is RuntimesCommand.RouteError {}

        XCTAssertEqual(try onDiskText(), original)
        try XCTAssertNil(try routedSection())
    }

    func testAddDockerRouteRequiresDockerConfig() async throws {
        // Engine validation gates every write: a docker route without a
        // `docker:` section is rejected (same policy as appleContainer).
        try installConfig(baseConfig)
        let original = try onDiskText()

        do {
            try await runRoute(["add", "acme/api", "docker"])
            XCTFail("docker route without docker: section must throw")
        } catch let error as RuntimesCommand.RouteError {
            XCTAssertTrue(error.message.contains("no docker: section"), error.message)
        }
        XCTAssertEqual(try onDiskText(), original)
    }

    func testAddDockerRoutePersistsRoute() async throws {
        try installConfig(baseConfig + "\ndocker:\n  image: \"ghcr.io/acme/kinhin-ci-linux\"\n")
        try await runRoute(["add", "acme/api", "docker"])

        let rc = try XCTUnwrap(try routedSection())
        XCTAssertEqual(rc.routes.first?.pattern, "acme/api")
        XCTAssertEqual(rc.routes.first?.runtime, "docker")
    }

    // MARK: remove

    func testRemoveDeletesOnlyTheTargetRoute() async throws {
        try installConfig(baseConfig + "\nruntimes:\n  default: tart\n  routes:\n    - pattern: \"acme/api\"\n      runtime: appleContainer\n    - pattern: \"acme/web@Nightly\"\n      runtime: appleContainer\n")
        try await runRoute(["remove", "acme/api"])

        let rc = try XCTUnwrap(try routedSection())
        XCTAssertEqual(rc.routes.map(\.pattern), ["acme/web@Nightly"], "only the targeted route is removed")
    }

    func testRemoveLastRouteKeepsTheSection() async throws {
        try installConfig(baseConfig + "\nruntimes:\n  default: appleContainer\n  budget: {tart: 0.5, appleContainer: 0.5}\n  routes:\n    - pattern: \"acme/api\"\n      runtime: appleContainer\n")
        try await runRoute(["remove", "acme/api"])

        let rc = try XCTUnwrap(try routedSection(), "removing the last route must not drop default/budget")
        XCTAssertTrue(rc.routes.isEmpty)
        XCTAssertEqual(rc.defaultRuntime, "appleContainer")
        XCTAssertEqual(rc.budget["tart"] ?? 0, 0.5, accuracy: 0.0001)
    }

    func testRemoveUnknownPatternLeavesFileUntouched() async throws {
        try installConfig(baseConfig + "\nruntimes:\n  default: tart\n")
        let original = try onDiskText()

        do {
            try await runRoute(["remove", "acme/nope"])
            XCTFail("unknown pattern must throw")
        } catch let error as RuntimesCommand.RouteError {
            XCTAssertTrue(error.message.contains("no route"))
        }

        XCTAssertEqual(try onDiskText(), original)
    }

    // MARK: routing table

    func testParseRoutesRuntimesHead() {
        XCTAssertEqual(CLICommand.parse(["runtimes"]), .runtimes)
        XCTAssertEqual(CLICommand.parse(["runtimes", "--json"]), .runtimes)
        XCTAssertEqual(CLICommand.parse(["runtimes", "route", "add", "acme/api", "tart"]), .runtimes)
        XCTAssertEqual(CLICommand.parse(["runtimes", "route", "remove", "acme/api"]), .runtimes)
        XCTAssertNil(CLICommand.parse(["runtime"]), "singular stays unknown")
    }

    func testRunSlicesTheRouteTail() {
        // `run` gets the full argv (head included) and must slice off
        // `runtimes route` before handing the tail to the editing core.
        // (Pinned directly because `run` exits the process on success.)
        XCTAssertEqual(RuntimesCommand.routeTail(["runtimes", "route", "add", "acme/api", "tart"]), ["add", "acme/api", "tart"])
        XCTAssertEqual(RuntimesCommand.routeTail(["runtimes", "route", "remove", "acme/api"]), ["remove", "acme/api"])
        XCTAssertNil(RuntimesCommand.routeTail(["runtimes"]), "bare runtimes is the summary")
        XCTAssertNil(RuntimesCommand.routeTail(["runtimes", "--json"]), "flags keep the summary form")
        XCTAssertNil(RuntimesCommand.routeTail(["runtimes", "router"]), "prefix must not match")
    }

    // MARK: argument handling

    func testUsageErrorsThrowWithoutTouchingDisk() async throws {
        try installConfig(baseConfig)
        let original = try onDiskText()

        let cases: [([String], String)] = [
            ([], "usage:"),
            (["add"], "missing pattern"),
            (["add", "acme/api"], "missing runtime"),
            (["remove"], "missing pattern"),
            (["frobnicate"], "usage:"),
            (["add", "@Bad", "tart"], "'@' cannot be first or last"),
            (["add", "acme/api@", "tart"], "'@' cannot be first or last"),
        ]
        for (argv, expectedSubstring) in cases {
            do {
                try await runRoute(argv)
                XCTFail("expected RouteError for \(argv)")
            } catch let error as RuntimesCommand.RouteError {
                XCTAssertTrue(error.message.contains(expectedSubstring), "\(argv): expected '\(expectedSubstring)' in '\(error.message)'")
            }
        }

        XCTAssertEqual(try onDiskText(), original)
    }
}
