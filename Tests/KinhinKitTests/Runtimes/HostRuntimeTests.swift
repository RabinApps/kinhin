import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The host runtime: consent-gated config, agent health, registration
/// script shape, work-dir lifecycle, and pool routing.
final class HostRuntimeTests: XCTestCase {
    private func makeRuntime() -> (HostRuntime, FakeShell, URL) {
        let shell = FakeShell()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-host-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (HostRuntime(shell: shell, agentDir: dir), shell, dir)
    }

    // MARK: Config validation (the consent gate)

    func testHostRouteWithoutConsentIsRejected() {
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                repo: "acme/widgets"
                labels: [x]
                runtimes:
                  routes:
                    - pattern: "acme/scripts"
                      runtime: host
                """)
        ) { error in
            guard case .invalid(let message) = error as? ConfigError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("consent: true"), message)
            XCTAssertTrue(message.contains("unisolated"), message)
        }
    }

    func testHostRouteWithConsentParses() throws {
        let cfg = try ConfigLoader.parse(
            """
            repo: "acme/widgets"
            labels: [x]
            runtimes:
              routes:
                - pattern: "acme/scripts"
                  runtime: host
                  consent: true
            """)
        let route = try XCTUnwrap(cfg.runtimes?.routes.first)
        XCTAssertEqual(route.consent, true)
        XCTAssertTrue(cfg.hostRoutesConfigured)
    }

    func testHostCannotBeTheDefaultRuntime() {
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                repo: "acme/widgets"
                labels: [x]
                runtimes:
                  default: host
                """)
        ) { error in
            guard case .invalid(let message) = error as? ConfigError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("default cannot be 'host'"), message)
        }
    }

    func testConsentIsRejectedOnNonHostRoutes() {
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                repo: "acme/widgets"
                labels: [x]
                runtimes:
                  routes:
                    - pattern: "acme/web"
                      runtime: appleContainer
                      consent: true
                """)
        ) { error in
            guard case .invalid(let message) = error as? ConfigError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("consent applies to host routes only"), message)
        }
    }

    func testNoHostRoutesMeansNoHostRuntime() throws {
        let cfg = try ConfigLoader.parse("repo: \"acme/widgets\"\nlabels: [x]\n")
        XCTAssertFalse(cfg.hostRoutesConfigured)
    }

    // MARK: Health

    func testHealthMissingWhenAgentAbsent() async {
        let (runtime, _, _) = makeRuntime()
        let health = await runtime.health()
        guard case .missing(let tool, _) = health else { return XCTFail("expected missing, got \(health)") }
        XCTAssertTrue(tool.contains("host runner agent"))
    }

    func testHealthReadyWhenAgentPresent() async throws {
        let (runtime, _, dir) = makeRuntime()
        FileManager.default.createFile(atPath: dir.appendingPathComponent("config.sh").path, contents: Data())
        let health = await runtime.health()
        XCTAssertEqual(health, .ready)
    }

    // MARK: Provision / teardown lifecycle

    func testProvisionCreatesWorkDirAndTeardownScrubsIt() async throws {
        let (runtime, _, _) = makeRuntime()
        let id = "kinhin-test123"
        try await runtime.provision(id: id, route: RepoRoute(repo: "acme", image: "img", ephemeral: true, bootTimeout: 5))
        let workDir = Paths.appSupport.appendingPathComponent("host-instances/\(id)", isDirectory: true)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: workDir.path, isDirectory: &isDir)
        XCTAssertTrue(exists && isDir.boolValue)
        // Adopt path: the existing-instance enumeration sees it (the shared
        // host-instances dir may also hold dirs from earlier tests).
        let existing = await runtime.existingInstanceIDs()
        XCTAssertTrue(existing.contains(id), "\(existing)")
        // Teardown scrubs (idempotent — a second call is a no-op).
        await runtime.teardown(id: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDir.path))
        await runtime.teardown(id: id)
    }

    func testAwaitReadyReturnsNilForLocalExec() async throws {
        let (runtime, _, _) = makeRuntime()
        let ip = try await runtime.awaitReady(id: "kinhin-x", timeout: 1)
        XCTAssertNil(ip, "exec transport needs no address")
    }

    // MARK: Registration script

    func testRegistrationScriptIsGitHubOnly() async {
        let (runtime, _, _) = makeRuntime()
        // A Gitea-family forge (Forgejo shares it) must be refused: the host
        // path only runs the GitHub agent.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = GiteaClient(
            credentials: GiteaCredentials(token: "gt", scope: "acme", instance: "https://gitea.example.com"),
            session: URLSession(configuration: config))
        let gitea = GiteaForge(
            credentials: .gitea(token: "gt", scope: "acme", instance: "https://gitea.example.com"),
            labels: ["macos:host"], client: client, registrationToken: "reg")
        do {
            _ = try await runtime.registrationScript(
                forge: gitea, token: "t", name: "kinhin-1", runnerCount: 1,
                route: RepoRoute(repo: "acme", image: "img", ephemeral: true, bootTimeout: 5), labels: nil)
            XCTFail("Gitea forges must not register on the host")
        } catch {
            // expected
        }
    }

    func testRegistrationScriptRedirectsWorkDirAndMergesHostLabel() async throws {
        let (runtime, _, agentDir) = makeRuntime()
        FileManager.default.createFile(atPath: agentDir.appendingPathComponent("config.sh").path, contents: Data())
        let github = GitHubForge(
            credentials: .github(token: "t", scope: "acme/widgets"),
            labels: ["kinhin"], client: FakeGitHub())
        let script = try await runtime.registrationScript(
            forge: github, token: "T", name: "kinhin-host1", runnerCount: 1,
            route: RepoRoute(repo: "acme", image: "img", ephemeral: true, bootTimeout: 5),
            labels: ["kinhin", "kinhin-host"])
        XCTAssertTrue(script.contains("--labels 'kinhin,kinhin-host'"))
        XCTAssertTrue(script.contains("kinhin-host1"))
        XCTAssertTrue(script.contains("host-instances/kinhin-host1"), "work dir is per-instance")
        XCTAssertTrue(script.contains("cd ~/actions-runner") == false, "the VM cd is overridden")
        // Executed through bash on the host, cwd = agent dir.
        try await runtime.provision(id: "kinhin-host1", route: RepoRoute(repo: "acme", image: "img", ephemeral: true, bootTimeout: 5))
    }

    // MARK: Pool labels

    func testHostPoolRegistersWithExclusiveMarker() {
        let labels = RuntimePool.labelsFor(.host, fleetLabels: ["self-hosted"])
        XCTAssertEqual(labels, ["self-hosted", "kinhin-host"], "host runners always carry the opt-in marker")
    }

    func testHostPoolJoinsRoutingWhenConfigured() {
        let routes = [KinhinConfig.RuntimeConfig.Route(pattern: "acme/scripts", runtime: "host", consent: true)]
        let model = RuntimeConfigModel(
            config: KinhinConfig.RuntimeConfig(defaultRuntime: "tart", routes: routes),
            fleetLabels: ["kinhin"], hostConfigured: true)
        XCTAssertTrue(model.poolExists(.host))
        // A job from the routed repo lands in the host pool.
        let job = ForgeJob(name: "build", runnerName: nil, repository: "acme/scripts")
        let defaultPool = RuntimePool(runtime: .tart, labels: ["kinhin"])
        let decision = RuntimeRouter.assign(job: job, config: model, defaultPool: defaultPool, pools: model.pools)
        XCTAssertEqual(decision.pool.runtime, .host)
        // Unrouted jobs never touch the host pool.
        let other = ForgeJob(name: "build", runnerName: nil, repository: "acme/other")
        let fallback = RuntimeRouter.assign(job: other, config: model, defaultPool: defaultPool, pools: model.pools)
        XCTAssertEqual(fallback.pool.runtime, .tart)
    }

    // MARK: Capacity

    func testHostSlotsParticipateInTheBudgetPartition() {
        let partition = RuntimeCapacity.partition(
            hostUsableCPU: 8, hostUsableMemoryGB: 16,
            weights: ["host": 0.5],
            defaultRuntime: .tart,
            shape: { id in id == .host ? (1, 1) : (4, 8) }
        )
        // Host gets half the budget: floor(8*0.5/1)=4 CPU, floor(16*0.5/1)=8 GB → 4.
        XCTAssertEqual(partition.caps[.host], 4)
        // Tart keeps the remainder: 4 CPU / 8 GB with shape 4/8 → 1.
        XCTAssertEqual(partition.caps[.tart], 1, "tart gets the remainder, at its VM shape")
    }
}
