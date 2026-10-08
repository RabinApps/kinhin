import XCTest

@testable import KinhinKit
@testable import kinhin

/// `kinhin workflow route` end to end: argument parsing carries the CLI's
/// exit codes, the pre-flight refuses bad targets, the workflow file is
/// edited comment-preservingly, and the config route is reconciled only when
/// routing precedence needs one — all against scratch files, with no daemon
/// to notify.
final class WorkflowRouteCommandTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-workflow-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    private var configURL: URL { scratch.appendingPathComponent("config.yaml") }
    private var workflowURL: URL { scratch.appendingPathComponent(".github/workflows/ci.yml") }

    /// The macOS-side config without routing; containers and a `runtimes:`
    /// section compose on top (container routes are rejected without one).
    private let baseYAML = """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: ["self-hosted", "macos", "arm64"]
        max_runners: 4
        poll_interval: 30
        vm:
          cpu: 4
          memory_gb: 8
        image: "tahoe-base"
        reserve:
          cpu: 2
          memory_gb: 4
        """

    private let containerYAML = """
        container:
          image: "kinhin-ci-linux"
          cpus: 2
          memory_gb: 4
        """

    /// A mixed fleet defaulting to tart (the label-marker path).
    private var mixedYAML: String {
        baseYAML + "\n" + containerYAML + "\nruntimes:\n  default: tart\n  budget: {tart: 0.5, appleContainer: 0.5}\n"
    }

    /// A mixed fleet defaulting to containers: tart is off the default, so
    /// routing to it needs a config route (tart carries no label marker).
    private var containerDefaultYAML: String {
        baseYAML + "\n" + containerYAML
            + "\nruntimes:\n  default: appleContainer\n  budget: {tart: 0.5, appleContainer: 0.5}\n"
    }

    private let workflow = """
        name: CI
        on: [push]
        jobs:
          build:
            runs-on: ubuntu-latest
            steps:
              - run: echo hi
          test:
            runs-on: [self-hosted, macos]
            steps:
              - run: echo test
        """

    private func install(config yaml: String) throws {
        try yaml.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func install(workflow yaml: String) throws {
        try FileManager.default.createDirectory(
            at: workflowURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try yaml.write(to: workflowURL, atomically: true, encoding: .utf8)
    }

    private func workflowText() throws -> String {
        try String(contentsOf: workflowURL, encoding: .utf8)
    }

    private func run(_ args: [String]) async throws {
        try await WorkflowRouteCommand.run(args, configURL: configURL, notifyDaemon: false)
    }

    private func routes() throws -> [KinhinConfig.RuntimeConfig.Route] {
        try ConfigLoader.load(from: configURL).runtimes?.routes ?? []
    }

    private func assertUsage(
        _ error: Error, containing needle: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let cli = error as? CLIError else {
            XCTFail("expected CLIError, got \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(cli.exit, .usage, file: file, line: line)
        XCTAssertTrue(cli.message.contains(needle), cli.message, file: file, line: line)
    }

    // MARK: - Argument parsing (exit 2 on every bad command line)

    func testParseRejectsBadCommandLines() {
        XCTAssertThrowsError(try WorkflowRouteCommand.parse([])) {
            assertUsage($0, containing: "missing target runtime")
        }
        XCTAssertThrowsError(try WorkflowRouteCommand.parse(["ci.yml"])) {
            assertUsage($0, containing: "missing target runtime")
        }
        XCTAssertThrowsError(try WorkflowRouteCommand.parse(["ci.yml", "windows"])) {
            assertUsage($0, containing: "missing target runtime")
        }
        XCTAssertThrowsError(try WorkflowRouteCommand.parse(["ci.yml", "appleContainer", "--nope"])) {
            assertUsage($0, containing: "unknown option: --nope")
        }
        XCTAssertThrowsError(try WorkflowRouteCommand.parse(["ci.yml", "appleContainer", "--job"])) {
            assertUsage($0, containing: "--job needs a job name")
        }
        XCTAssertThrowsError(try WorkflowRouteCommand.parse(["ci.yml", "appleContainer", "extra"])) {
            assertUsage($0, containing: "unexpected: extra")
        }
    }

    func testHostRequiresConsentAndConsentIsHostOnly() {
        XCTAssertThrowsError(try WorkflowRouteCommand.parse(["ci.yml", "host"])) {
            assertUsage($0, containing: "--consent")
        }
        XCTAssertThrowsError(try WorkflowRouteCommand.parse(["ci.yml", "tart", "--consent"])) {
            assertUsage($0, containing: "--consent applies to host routes only")
        }
        XCTAssertNoThrow(try WorkflowRouteCommand.parse(["ci.yml", "host", "--consent"]))
        // Either positional order: <file> <runtime> or <runtime> <file>.
        XCTAssertNoThrow(try WorkflowRouteCommand.parse(["appleContainer", "ci.yml"]))
    }

    func testHelpIsAUsageError() {
        XCTAssertThrowsError(try WorkflowRouteCommand.parse(["--help"])) {
            assertUsage($0, containing: "usage: kinhin workflow route")
        }
    }

    // MARK: - Pre-flight

    func testMissingConfigExitsWithTheSetupCommand() async throws {
        try install(workflow: workflow)
        do {
            try await run([workflowURL.path, "tart"])
            XCTFail("expected a missing-config error")
        } catch let error as CLIError {
            XCTAssertEqual(error.exit, .config)
            XCTAssertTrue(error.message.contains("kinhin config init"), error.message)
        }
    }

    func testUnconfiguredPoolIsRefusedWithSetupHint() async throws {
        try install(config: baseYAML)  // no container: section
        try install(workflow: workflow)
        do {
            try await run([workflowURL.path, "appleContainer"])
            XCTFail("expected a missing-pool error")
        } catch {
            assertUsage(error, containing: "no configured pool")
            XCTAssertTrue("\(error)".contains("image prepare --container"), "\(error)")
        }
    }

    func testLabelTargetingIncompatibleForgeIsRefused() async throws {
        try install(config: baseYAML.replacingOccurrences(of: "forge: github", with: "forge: gitlab"))
        try install(workflow: workflow)
        do {
            try await run([workflowURL.path, "tart"])
            XCTFail("expected the label-targeting refusal")
        } catch {
            assertUsage(error, containing: "kinhin runtimes route add")
        }
    }

    // MARK: - The happy paths

    /// Marker runtime, no conflicting route: the label edit alone carries the
    /// job, so no config route is written.
    func testRouteToContainerEditsLabelsAndNeedsNoRoute() async throws {
        try install(config: mixedYAML)
        try install(workflow: workflow)
        try await run([workflowURL.path, "appleContainer"])

        let edited = try workflowText()
        // ubuntu-latest can never match kinhin's runners: replaced wholesale.
        XCTAssertTrue(edited.contains("runs-on: [self-hosted, macos, arm64, kinhin-container]"), edited)
        // A subset of the pool's labels keeps its labels and gains the marker.
        XCTAssertTrue(edited.contains("runs-on: [self-hosted, macos, kinhin-container]"), edited)
        XCTAssertTrue(edited.contains("name: CI"), "the rest of the file is untouched")

        XCTAssertTrue(try routes().isEmpty, "the marker uniquely targets the pool — no route needed")
        let reparsed = try parseWorkflow(Data(edited.utf8), at: workflowURL)
        XCTAssertEqual(reparsed.jobs.count, 2)
    }

    func testJobFlagRoutesOnlyThatJob() async throws {
        try install(config: mixedYAML)
        try install(workflow: workflow)
        try await run([workflowURL.path, "appleContainer", "--job", "build"])

        let edited = try workflowText()
        XCTAssertTrue(edited.contains("runs-on: [self-hosted, macos, arm64, kinhin-container]"), edited)
        XCTAssertTrue(edited.contains("runs-on: [self-hosted, macos]\n"), "the untargeted job is untouched")
    }

    /// tart carries no label marker: off the default, only a workflow route
    /// can carry it — and the pool labels replace the GitHub-hosted scalar.
    func testRouteToTartOffDefaultWritesWorkflowRoute() async throws {
        try install(config: containerDefaultYAML)
        try install(workflow: workflow)
        try await run([workflowURL.path, "tart"])

        let configRoutes = try routes()
        XCTAssertEqual(configRoutes.count, 1)
        XCTAssertEqual(configRoutes[0].pattern, "acme/widgets@CI")
        XCTAssertEqual(configRoutes[0].runtime, .tart)

        let edited = try workflowText()
        XCTAssertTrue(edited.contains("runs-on: [self-hosted, macos, arm64]\n"), edited)
        XCTAssertTrue(edited.contains("runs-on: [self-hosted, macos]\n"), "already correct, untouched")

        // The default didn't move as a side effect.
        XCTAssertEqual(try ConfigLoader.load(from: configURL).runtimes?.defaultRuntime, .appleContainer)
    }

    /// A repo route outranks the marker — a workflow route must override it
    /// or the job would land in the routed pool instead of the target.
    func testConflictingRepoRouteIsOverriddenByWorkflowRoute() async throws {
        try install(
            config: baseYAML + "\n" + containerYAML + """
                \nruntimes:
                  default: tart
                  routes:
                    - pattern: "acme/widgets"
                      runtime: appleContainer
                """)
        try install(workflow: workflow)
        try await run([workflowURL.path, "tart"])

        let configRoutes = try routes()
        XCTAssertEqual(configRoutes.count, 2)
        XCTAssertEqual(configRoutes[1].pattern, "acme/widgets@CI")
        XCTAssertEqual(configRoutes[1].runtime, .tart)
        XCTAssertEqual(configRoutes[0].runtime, .appleContainer, "the existing repo route stays")
    }

    /// A `${{ }}` job can't be edited — it's reported SKIPPED, the file stays
    /// untouched, and the workflow route carries it to the target instead.
    func testExpressionJobIsRefusedAndRouteCarriesIt() async throws {
        let expressionWorkflow = """
            name: CI
            on: [push]
            jobs:
              matrix:
                runs-on: ${{ matrix.os }}
                steps:
                  - run: echo hi
            """
        try install(config: mixedYAML)
        try install(workflow: expressionWorkflow)
        try await run([workflowURL.path, "appleContainer"])

        XCTAssertEqual(try workflowText(), expressionWorkflow, "a refused job is never rewritten")
        let configRoutes = try routes()
        XCTAssertEqual(configRoutes.count, 1)
        XCTAssertEqual(configRoutes[0].pattern, "acme/widgets@CI")
        XCTAssertEqual(configRoutes[0].runtime, .appleContainer)
    }

    /// `--dry-run` reports the plan — edits *and* route — without touching
    /// either file.
    func testDryRunWritesNothing() async throws {
        try install(config: containerDefaultYAML)
        try install(workflow: workflow)
        try await run([workflowURL.path, "tart", "--dry-run"])

        XCTAssertEqual(try workflowText(), workflow, "the workflow must not change")
        XCTAssertTrue(try routes().isEmpty, "the config must not change")
    }

    func testResolvesWorkflowByName() async throws {
        try install(config: mixedYAML)
        try install(workflow: workflow)
        let cwd = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(scratch.path))
        defer { _ = FileManager.default.changeCurrentDirectoryPath(cwd) }

        try await run(["CI", "appleContainer"])
        XCTAssertTrue(try workflowText().contains("kinhin-container"))
    }

    /// Host: consent is required up front, and the route that opts the host
    /// pool in carries `consent: true` while keeping the effective default.
    func testHostRouteRequiresAndCarriesConsent() async throws {
        try install(config: baseYAML)
        try install(workflow: workflow)

        do {
            try await run([workflowURL.path, "host"])
            XCTFail("expected the consent refusal")
        } catch {
            assertUsage(error, containing: "--consent")
        }

        try await run([workflowURL.path, "host", "--consent"])
        let configRoutes = try routes()
        XCTAssertEqual(configRoutes.count, 1)
        XCTAssertEqual(configRoutes[0].pattern, "acme/widgets@CI")
        XCTAssertEqual(configRoutes[0].runtime, .host)
        XCTAssertEqual(configRoutes[0].consent, true)
        XCTAssertEqual(try ConfigLoader.load(from: configURL).runtimes?.defaultRuntime, .tart)

        XCTAssertTrue(
            try workflowText().contains("runs-on: [self-hosted, macos, arm64, kinhin-host]"),
            "the host pool registers with the fleet labels plus its marker")
    }
}
