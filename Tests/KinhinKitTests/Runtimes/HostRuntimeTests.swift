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

    func testHealthReadyWhenBothAgentsPresent() async throws {
        let (runtime, _, dir) = makeRuntime()
        FileManager.default.createFile(atPath: dir.appendingPathComponent("config.sh").path, contents: Data())
        let gitea = dir.appendingPathComponent("gitea-runner").path
        FileManager.default.createFile(atPath: gitea, contents: Data(), attributes: [.posixPermissions: 0o755])
        let health = await runtime.health()
        XCTAssertEqual(health, .ready)
    }

    func testHealthMissingWhenOnlyTheGitHubAgentIsPresent() async throws {
        let (runtime, _, dir) = makeRuntime()
        FileManager.default.createFile(atPath: dir.appendingPathComponent("config.sh").path, contents: Data())
        guard case .missing(_, let fix) = await runtime.health() else { return XCTFail("expected missing") }
        XCTAssertTrue(fix.contains("kinhin setup repair host-agent"))
    }

    // MARK: Provision / teardown lifecycle

    func testProvisionCreatesWorkDirAndTeardownScrubsIt() async throws {
        let (runtime, _, _) = makeRuntime()
        let id = "kinhin-test123"
        try await runtime.provision(
            id: id, route: RepoRoute(repo: "acme", image: "img", ephemeral: true, bootTimeout: 5))
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

    private func giteaForge(family: ForgeID = .gitea, labels: [String] = ["macos:host"]) -> GiteaForge {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = GiteaClient(
            credentials: GiteaCredentials(token: "gt", scope: "acme", instance: "https://gitea.example.com"),
            session: URLSession(configuration: config))
        let credentials: ForgeCredentials =
            family == .forgejo
            ? .forgejo(token: "gt", scope: "acme", instance: "https://gitea.example.com")
            : .gitea(token: "gt", scope: "acme", instance: "https://gitea.example.com")
        return GiteaForge(credentials: credentials, labels: labels, client: client, registrationToken: "reg")
    }

    private let route = RepoRoute(repo: "acme", image: "img", ephemeral: true, bootTimeout: 5)

    func testGiteaRegistrationScriptRunsTheDaemonOnTheHost() async throws {
        let (runtime, _, agentDir) = makeRuntime()
        let script = try await runtime.registrationScript(
            forge: giteaForge(), token: "ignored", name: "kinhin-g1", runnerCount: 1, route: route, labels: nil)
        XCTAssertTrue(script.contains(agentDir.appendingPathComponent("gitea-runner").path))
        XCTAssertTrue(script.contains("register --no-interactive"))
        XCTAssertTrue(script.contains("--instance 'https://gitea.example.com'"))
        XCTAssertTrue(script.contains("--token 'reg'"), "the forge's long-lived registration token is used")
        XCTAssertTrue(script.contains("--name 'kinhin-g1'"))
        XCTAssertTrue(script.contains("--labels 'macos:host,kinhin-host:host'"), script)
        XCTAssertTrue(script.contains("host-instances/kinhin-g1/gitea-1"), "state lives in the scrubbed instance dir")
        XCTAssertTrue(script.contains("workdir_parent"), "job workspaces are redirected into the instance dir")
        XCTAssertTrue(script.contains("daemon.pid"), "teardown needs the pid to stop the daemon")
        XCTAssertFalse(script.contains("--ephemeral"))
    }

    func testForgejoUsesTheSameHostFlow() async throws {
        let (runtime, _, _) = makeRuntime()
        let script = try await runtime.registrationScript(
            forge: giteaForge(family: .forgejo), token: "", name: "kinhin-f1", runnerCount: 1, route: route,
            labels: nil)
        XCTAssertTrue(script.contains("register --no-interactive"))
    }

    func testGiteaRunnersPerVMGetIndexedNames() async throws {
        let (runtime, _, _) = makeRuntime()
        let script = try await runtime.registrationScript(
            forge: giteaForge(), token: "", name: "kinhin-g2", runnerCount: 2, route: route, labels: nil)
        XCTAssertTrue(script.contains("--name 'kinhin-g2-r1'"))
        XCTAssertTrue(script.contains("--name 'kinhin-g2-r2'"), "matches the names awaitGiteaExit expects")
        XCTAssertTrue(script.contains("gitea-2"))
    }

    func testHostLabelsForceTheHostSchemeAndAddTheMarker() {
        XCTAssertEqual(
            HostRuntime.hostLabels(["macos:host", "ubuntu-latest:docker://node:20", "arm64", "arm64:host"]),
            ["macos:host", "ubuntu-latest:host", "arm64:host", "kinhin-host:host"],
            "docker-scheme and bare labels must not make the daemon start containers; duplicates collapse")
    }

    func testTeardownStopsGiteaDaemonsBeforeScrubbing() async throws {
        let (runtime, shell, _) = makeRuntime()
        let id = "kinhin-gtd\(UUID().uuidString.prefix(6))"
        try await runtime.provision(id: id, route: route)
        let instanceDir = runtime.workDirectory(for: id).appendingPathComponent("gitea-1", isDirectory: true)
        try FileManager.default.createDirectory(at: instanceDir, withIntermediateDirectories: true)
        await runtime.teardown(id: id)
        let stop = try XCTUnwrap(shell.calls.first { $0.last?.contains("daemon.pid") == true }, "\(shell.calls)")
        XCTAssertTrue(stop.last?.contains("gitea-runner.* daemon") ?? false, "only kills a pid that is still a daemon")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.workDirectory(for: id).path))
    }

    func testTeardownOfAGitHubInstanceRunsNoShellCommands() async throws {
        let (runtime, shell, _) = makeRuntime()
        let id = "kinhin-ghd\(UUID().uuidString.prefix(6))"
        try await runtime.provision(id: id, route: route)
        await runtime.teardown(id: id)
        XCTAssertTrue(shell.calls.isEmpty)
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
        try await runtime.provision(
            id: "kinhin-host1", route: RepoRoute(repo: "acme", image: "img", ephemeral: true, bootTimeout: 5))
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
