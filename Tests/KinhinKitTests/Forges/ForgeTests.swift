import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Multi-forge support: the Gitea client, the unified Forge surface, demand
/// merging / per-VM platform assignment, the Gitea bootstrap script, and the
/// token-gated image provisioning rule (an agent is baked only when that
/// platform's token exists).
final class ForgeTests: XCTestCase {
    // MARK: - Gitea client routing

    private func makeGiteaClient(scope: String) -> GiteaClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return GiteaClient(
            credentials: GiteaCredentials(token: "gt", scope: scope, instance: "https://gitea.example.com"),
            session: URLSession(configuration: config)
        )
    }

    func testGiteaRepoScopeRoutesToRepoEndpoints() async throws {
        let paths = Mutex<[String]>([])
        StubProtocol.handler = { request in
            paths.withLock { $0.append(request.url?.path ?? "") }
            if request.url?.path.hasSuffix("/registration-token") == true {
                return (200, Data("{\"token\":\"gt-reg\"}".utf8), [:])
            }
            return (200, Data("{\"total_count\":0,\"runners\":[]}".utf8), [:])
        }
        defer { StubProtocol.handler = nil }

        let client = makeGiteaClient(scope: "acme/widgets")
        let token = try await client.fetchRegistrationToken()
        _ = try await client.listRunners()
        XCTAssertTrue(
            paths.withLock { $0 }.contains("/api/v1/repos/acme/widgets/actions/runners/registration-token"),
            "\(paths.withLock { $0 })")
        XCTAssertTrue(
            paths.withLock { $0 }.contains("/api/v1/repos/acme/widgets/actions/runners"), "\(paths.withLock { $0 })")
        XCTAssertEqual(token, "gt-reg")
    }

    func testGiteaOrgScopeRoutesToOrgEndpoints() async throws {
        let paths = Mutex<[String]>([])
        StubProtocol.handler = { request in
            paths.withLock { $0.append(request.url?.path ?? "") }
            return (200, Data("{\"token\":\"t\"}".utf8), [:])
        }
        defer { StubProtocol.handler = nil }

        let client = makeGiteaClient(scope: "acme")
        _ = try await client.fetchRegistrationToken()
        XCTAssertTrue(
            paths.withLock { $0 }.contains("/api/v1/orgs/acme/actions/runners/registration-token"),
            "\(paths.withLock { $0 })")
    }

    func testGiteaAuthHeaderUsesTokenScheme() async throws {
        let auth = Mutex<String?>(nil)
        StubProtocol.handler = { request in
            auth.withLock { $0 = request.value(forHTTPHeaderField: "Authorization") }
            return (200, Data("{\"token\":\"t\"}".utf8), [:])
        }
        defer { StubProtocol.handler = nil }

        _ = try await makeGiteaClient(scope: "acme").fetchRegistrationToken()
        XCTAssertEqual(auth.withLock { $0 }, "token gt", "Gitea uses 'token <value>', not Bearer")
    }

    func testGiteaErrorMapping() async {
        StubProtocol.handler = { _ in (401, Data("nope".utf8), [:]) }
        defer { StubProtocol.handler = nil }
        do {
            _ = try await makeGiteaClient(scope: "acme").fetchRegistrationToken()
            XCTFail("should throw")
        } catch let error as ForgeAPIError {
            XCTAssertEqual(error, .unauthorized(forge: .gitea))
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testGiteaCredentialsValidateInstance() {
        XCTAssertThrowsError(try GiteaCredentials.validate(instance: "gitea.example.com"))
        XCTAssertThrowsError(try GiteaCredentials.validate(instance: "https://gitea.example.com/api"))
        XCTAssertNoThrow(try GiteaCredentials.validate(instance: "https://gitea.example.com"))
        // Plain http to a LAN host needs the account's explicit opt-in.
        XCTAssertThrowsError(try GiteaCredentials.validate(instance: "http://192.168.8.8:3000"))
        XCTAssertNoThrow(try GiteaCredentials.validate(instance: "http://192.168.8.8:3000", allowInsecureHTTP: true))
    }

    // MARK: - GitHub forge mapping

    func testGitHubForgeMapsUnifiedSurface() async throws {
        let github = FakeGitHub()
        github.register(name: "kinhin-1", busy: true)
        github.queueDepth = 2
        github.queueRepos = ["acme/ios-app"]
        let forge = GitHubForge(
            credentials: .github(token: "t", scope: "acme/widgets"), labels: ["kinhin"], client: github)

        let runners = try await forge.runners()
        XCTAssertEqual(runners, [ForgeRunner(id: runners.first?.id ?? "", name: "kinhin-1", busy: true)])
        let queued = try await forge.queuedJobs()
        XCTAssertEqual(queued.count, 2)
        XCTAssertEqual(queued.first?.repository, "acme/ios-app")
        XCTAssertEqual(forge.registrationURL(), "https://github.com/acme/widgets")
    }

    func testNumericForgeDeletesRunnersByStringID() async throws {
        let github = FakeGitHub()
        github.register(name: "kinhin-1")
        let forge = GitHubForge(
            credentials: .github(token: "t", scope: "acme/widgets"), labels: ["kinhin"], client: github)

        let runners = try await forge.runners()
        let id = try XCTUnwrap(runners.first?.id)
        try await forge.deleteRunner(id: id)
        XCTAssertEqual(github.deletedRunnerIDs.map(String.init), [id])

        do {
            try await forge.deleteRunner(id: "not-a-number")
            XCTFail("a non-numeric id must not reach the GitHub API")
        } catch EngineError.invalidRunnerID(let forgeID, let badID) {
            XCTAssertEqual(forgeID, .github)
            XCTAssertEqual(badID, "not-a-number")
        }
    }

    // MARK: - Demand merging & assignment

    func testMergeQueueByRepoAcrossForges() {
        let githubJobs = [ForgeJob(name: "a", runnerName: nil, repository: "acme/ios-app")]
        let giteaJobs = [ForgeJob(name: "b", runnerName: nil, repository: "acme/api")]
        let merged = ForgeDemand.mergeQueueByRepo([
            .github: (true, githubJobs),
            .gitea: (true, giteaJobs),
        ])
        XCTAssertEqual(merged, ["acme/ios-app": 1, "acme/api": 1])
    }

    func testMergeSuppressesRepoScopedForge() {
        let githubJobs = [ForgeJob(name: "a", runnerName: nil, repository: "acme/widgets")]
        let giteaJobs = [ForgeJob(name: "b", runnerName: nil, repository: "acme/api")]
        let merged = ForgeDemand.mergeQueueByRepo([
            .github: (false, githubJobs),
            .gitea: (true, giteaJobs),
        ])
        XCTAssertEqual(merged, ["acme/api": 1], "repo-scoped forge's breakdown is suppressed")
        XCTAssertNil(ForgeDemand.mergeQueueByRepo([.github: (false, githubJobs)]), "all-repo-scope → nil breakdown")
    }

    func testAssignPlatformPicksLargestUnmetDemand() {
        // GitHub has 3 unmet, Gitea 1 → GitHub.
        XCTAssertEqual(
            ForgeDemand.assignPlatform(demand: [.github: 3, .gitea: 1], active: [:], attached: [.github, .gitea]),
            .github
        )
        // Gitea now has the bigger backlog → Gitea.
        XCTAssertEqual(
            ForgeDemand.assignPlatform(
                demand: [.github: 1, .gitea: 4], active: [.gitea: 2], attached: [.github, .gitea]),
            .gitea
        )
        // No demand anywhere → GitHub (stable default).
        XCTAssertEqual(
            ForgeDemand.assignPlatform(demand: [:], active: [:], attached: [.github, .gitea]),
            .github
        )
        // Detached forges are never assigned.
        XCTAssertEqual(
            ForgeDemand.assignPlatform(demand: [.gitea: 9], active: [:], attached: [.github]),
            .github
        )
    }

    // MARK: - Gitea demand attribution

    /// A GiteaForge whose client rides StubProtocol (make() builds its own
    /// session, which would escape the stub and hit the network).
    private func makeStubbedGiteaForge(demandFloor: Int = 0) -> GiteaForge {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = GiteaClient(
            credentials: GiteaCredentials(token: "gt", scope: "acme", instance: "https://gitea.example.com"),
            session: URLSession(configuration: config))
        return GiteaForge(
            credentials: .gitea(token: "gt", scope: "acme", instance: "https://gitea.example.com"),
            labels: ["macos:host"], client: client, demandFloor: demandFloor, registrationToken: "reg")
    }

    func testGiteaQueuedJobsCarryRepoAttribution() async throws {
        StubProtocol.handler = { request in
            if request.url?.path.hasSuffix("/actions/tasks") == true {
                return (
                    200,
                    Data(
                        """
                        {"total_count":2,"entries":[
                          {"id":1,"name":"build","status":"waiting","repo_full_name":"acme/api"},
                          {"id":2,"name":"test","status":"waiting","repo_full_name":"acme/web"}
                        ]}
                        """.utf8), [:]
                )
            }
            return (200, Data("{\"total_count\":0,\"runners\":[]}".utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let jobs = try await makeStubbedGiteaForge().queuedJobs()
        XCTAssertEqual(jobs.map { $0.repository ?? "-" }, ["acme/api", "acme/web"])
        XCTAssertEqual(jobs.first?.name, "build")
    }

    func testGiteaQueuedJobsPropagateEndpointFailures() async throws {
        StubProtocol.handler = { _ in (200, Data("<html>not json</html>".utf8), [:]) }
        defer { StubProtocol.handler = nil }
        do {
            _ = try await makeStubbedGiteaForge().queuedJobs()
            XCTFail("expected the endpoint failure to propagate")
        } catch let error as ForgeAPIError {
            guard case .decoding = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testGiteaQueuedJobsHoldFloorOnlyWhenQueueLooksEmpty() async throws {
        StubProtocol.handler = { _ in
            (200, Data("{\"total_count\":0,\"entries\":[]}".utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let heldCount = try await makeStubbedGiteaForge(demandFloor: 2).queuedJobs().count
        XCTAssertEqual(heldCount, 2, "empty answer holds the floor")
    }

    func testGiteaQueuedJobsRealZeroOverridesFloor() async throws {
        StubProtocol.handler = { _ in
            // A genuine empty queue with a zero total_count: 0 wins over the
            // floor (the TaskQueueWrapper only synthesizes when count > 0).
            (200, Data("{\"total_count\":0,\"entries\":[]}".utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let overrideCount = try await makeStubbedGiteaForge(demandFloor: 3).queuedJobs().count
        XCTAssertEqual(overrideCount, 3)
    }

    func testGiteaRunningJobsPreferRunningTasks() async throws {
        StubProtocol.handler = { request in
            if request.url?.query?.contains("status=running") == true {
                return (
                    200,
                    Data(
                        """
                        {"total_count":1,"entries":[{"id":9,"name":"deploy","status":"running",
                         "runner_name":"kinhin-vm1","repo_full_name":"acme/api"}]}
                        """.utf8), [:]
                )
            }
            return (200, Data("{\"total_count\":0,\"runners\":[]}".utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let running = try await makeStubbedGiteaForge().runningJobs()
        XCTAssertEqual(running.first?.runnerName, "kinhin-vm1")
        XCTAssertEqual(running.first?.repository, "acme/api")
    }

    func testGiteaRunningJobsFallBackToBusyRunners() async throws {
        StubProtocol.handler = { request in
            if request.url?.query?.contains("status=running") == true {
                return (200, Data("{\"total_count\":0,\"entries\":[]}".utf8), [:])
            }
            return (
                200,
                Data(
                    """
                    {"total_count":2,"runners":[{"id":1,"name":"kinhin-a","status":"busy"},
                    {"id":2,"name":"kinhin-b","status":"idle"}]}
                    """.utf8), [:]
            )
        }
        defer { StubProtocol.handler = nil }
        let running = try await makeStubbedGiteaForge().runningJobs()
        XCTAssertEqual(running.compactMap(\.runnerName), ["kinhin-a"], "only busy runners attribute")
    }

    // MARK: - Gitea bootstrap script

    func testGiteaRegistrationScriptSingleRunner() {
        let script = RunnerBootstrap.giteaRegistrationScript(
            instance: "https://gitea.example.com", token: "T", labels: ["macos:host"], name: "kinhin-1"
        )
        XCTAssertTrue(script.contains("--no-interactive"))
        XCTAssertTrue(script.contains("--instance 'https://gitea.example.com'"))
        XCTAssertTrue(script.contains("--token 'T'"))
        XCTAssertTrue(script.contains("--name 'kinhin-1'"))
        XCTAssertTrue(script.contains("--labels 'macos:host'"))
        XCTAssertTrue(script.contains("gitea-runner daemon"))
        XCTAssertFalse(script.contains("-r2"))
    }

    func testGiteaRegistrationScriptMultipleRunners() {
        let script = RunnerBootstrap.giteaRegistrationScript(
            instance: "https://g.example.com", token: "T", labels: ["macos:host"], name: "vm", runnerCount: 3
        )
        XCTAssertTrue(script.contains("--name 'vm-r1'"))
        XCTAssertTrue(script.contains("--name 'vm-r2'"))
        XCTAssertTrue(script.contains("--name 'vm-r3'"))
        XCTAssertTrue(script.contains("gitea-runner-2"))
        XCTAssertEqual(script.components(separatedBy: "gitea-runner daemon").count - 1, 3, "one daemon per runner")
    }

    func testGiteaRunnerInstallScriptDownloadsDarwinArm64() {
        let script = RunnerBootstrap.giteaRunnerInstallScript(version: "3.5.0")
        XCTAssertTrue(
            script.contains(
                "https://gitea.com/gitea/runner/releases/download/v3.5.0/gitea-runner-3.5.0-darwin-arm64.xz"))
    }

    // MARK: - Token-gated image provisioning

    func testImagePrepareFailsWithoutAnyPlatformToken() async {
        let preparer = ImagePreparer(tart: FakeTart(), ssh: FakeSSH())
        do {
            _ = try await preparer.run(
                ImagePreparer.Options(
                    hasGitHubToken: false, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                    hasAzureDevOpsToken: false))
            XCTFail("prepare must refuse when no platform token exists")
        } catch let error as ImageError {
            guard case .noCredentials = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testImagePrepareBakesOnlyTokenizedPlatforms() async throws {
        let tart = FakeTart()
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: tart, ssh: ssh)
        _ = try await preparer.run(
            ImagePreparer.Options(
                hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false))

        let script = ssh.scripts.joined(separator: "\n")
        XCTAssertTrue(script.contains("actions-runner-osx-arm64"), "GitHub agent baked when PAT exists")
        XCTAssertFalse(script.contains("gitea-runner"), "gitea runner skipped when no Gitea token")
    }

    func testImagePrepareBakesGiteaWhenTokenPresent() async throws {
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: FakeTart(), ssh: ssh)
        _ = try await preparer.run(
            ImagePreparer.Options(
                hasGitHubToken: false, hasGiteaToken: true, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false))

        let script = ssh.scripts.joined(separator: "\n")
        XCTAssertFalse(script.contains("actions-runner-osx-arm64"), "GitHub agent skipped when no PAT")
        XCTAssertTrue(script.contains("gitea.com/gitea/runner/releases"), "gitea runner baked when token exists")
    }

    // MARK: - Config gitea account

    func testConfigParsesGiteaAccount() throws {
        let yaml = """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
              - name: gitea
                forge: gitea
                instance: "https://gitea.example.com"
                scope: "acme"
                labels: ["macos:host"]
            labels: ["self-hosted"]
            """
        let cfg = try ConfigLoader.parse(yaml)
        XCTAssertEqual(cfg.gitea?.instance, "https://gitea.example.com")
        XCTAssertEqual(cfg.gitea?.scope, "acme")
        XCTAssertEqual(cfg.gitea?.labels, ["macos:host"])
    }

    func testConfigRejectsInvalidGiteaAccount() {
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                accounts:
                  - name: gitea
                    forge: gitea
                    scope: "acme"
                labels: ["self-hosted"]
                """), "missing instance must be rejected")
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                accounts:
                  - name: gitea
                    forge: gitea
                    instance: "not a url"
                    scope: "acme"
                labels: ["self-hosted"]
                """), "non-URL instance must be rejected")
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                accounts:
                  - name: gitea
                    forge: gitea
                    instance: "https://gitea.example.com"
                    scope: "a/b/c"
                labels: ["self-hosted"]
                """), "invalid scope must be rejected")
    }

    func testConfigWithoutGiteaSectionParsesCleanly() throws {
        let cfg = try ConfigLoader.parse(
            "accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\nlabels: [\"self-hosted\"]")
        XCTAssertNil(cfg.gitea)
    }

    // MARK: - Version resolver

    func testVersionResolverFallsBackWhenOffline() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.handler = { _ in (500, Data("nope".utf8), [:]) }
        defer { StubProtocol.handler = nil }

        let resolver = RunnerVersionResolver(session: URLSession(configuration: config))
        let versions = await resolver.resolve()
        XCTAssertEqual(versions, RunnerVersionResolver.fallback, "feed failure must degrade to pinned versions")
    }

    func testVersionResolverParsesBothFeeds() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.handler = { request in
            let host = request.url?.host ?? ""
            if host == "api.github.com" {
                return (200, Data("{\"tag_name\":\"v2.337.0\"}".utf8), [:])
            }
            if host == "gitlab.com" {
                return (200, Data("{\"tag_name\":\"v19.5.0\"}".utf8), [:])
            }
            return (200, Data("{\"tag_name\":\"v3.5.0\"}".utf8), [:])
        }
        defer { StubProtocol.handler = nil }

        let resolver = RunnerVersionResolver(session: URLSession(configuration: config))
        let versions = await resolver.resolve()
        XCTAssertEqual(versions.github, "2.337.0")
        XCTAssertEqual(versions.gitea, "3.5.0")
        XCTAssertEqual(versions.gitlab, "19.5.0")
    }

    // MARK: - Shared behavior

    func testScopeAttributionFollowsTheScopeShape() {
        let org = GitHubForge(credentials: GitHubCredentials(token: "t", scope: "acme"), labels: [])
        let repo = GitHubForge(credentials: GitHubCredentials(token: "t", scope: "acme/widgets"), labels: [])
        XCTAssertTrue(org.attributesByRepo)
        XCTAssertFalse(repo.attributesByRepo)
        XCTAssertEqual(repo.scope, "acme/widgets")
        XCTAssertEqual(org.registration, .sharedShortLived)
        XCTAssertEqual(org.exitSemantics, .deregisters)
    }

    func testRunnerNamesPerInstance() {
        XCTAssertEqual(FleetEngine.runnerNames(for: "kinhin-1", count: 1), ["kinhin-1"])
        XCTAssertEqual(FleetEngine.runnerNames(for: "kinhin-1", count: 0), ["kinhin-1"])
        XCTAssertEqual(FleetEngine.runnerNames(for: "kinhin-1", count: 2), ["kinhin-1-r1", "kinhin-1-r2"])
    }
}
