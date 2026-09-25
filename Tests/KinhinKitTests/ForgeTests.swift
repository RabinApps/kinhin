import XCTest

@testable import KinhinKit

/// Multi-forge support: the Gitea client, the unified Forge surface, demand
/// merging / per-VM platform assignment, the Gitea bootstrap script, and the
/// token-gated image provisioning rule (an agent is baked only when that
/// platform's token exists).
final class ForgeTests: XCTestCase {
    // MARK: Gitea client routing

    private func makeGiteaClient(scope: String) -> GiteaClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return GiteaClient(
            credentials: GiteaCredentials(token: "gt", scope: scope, instance: "https://gitea.example.com"),
            session: URLSession(configuration: config)
        )
    }

    func testGiteaRepoScopeRoutesToRepoEndpoints() async throws {
        var paths: [String] = []
        StubProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            if request.url?.path.hasSuffix("/registration-token") == true {
                return (200, Data("{\"token\":\"gt-reg\"}".utf8), [:])
            }
            return (200, Data("{\"total_count\":0,\"runners\":[]}".utf8), [:])
        }
        defer { StubProtocol.handler = nil }

        let client = makeGiteaClient(scope: "acme/widgets")
        let token = try await client.fetchRegistrationToken()
        _ = try await client.listRunners()
        XCTAssertTrue(paths.contains("/api/v1/repos/acme/widgets/actions/runners/registration-token"), "\(paths)")
        XCTAssertTrue(paths.contains("/api/v1/repos/acme/widgets/actions/runners"), "\(paths)")
        XCTAssertEqual(token, "gt-reg")
    }

    func testGiteaOrgScopeRoutesToOrgEndpoints() async throws {
        var paths: [String] = []
        StubProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            return (200, Data("{\"token\":\"t\"}".utf8), [:])
        }
        defer { StubProtocol.handler = nil }

        let client = makeGiteaClient(scope: "acme")
        _ = try await client.fetchRegistrationToken()
        XCTAssertTrue(paths.contains("/api/v1/orgs/acme/actions/runners/registration-token"), "\(paths)")
    }

    func testGiteaAuthHeaderUsesTokenScheme() async throws {
        var auth: String?
        StubProtocol.handler = { request in
            auth = request.value(forHTTPHeaderField: "Authorization")
            return (200, Data("{\"token\":\"t\"}".utf8), [:])
        }
        defer { StubProtocol.handler = nil }

        _ = try await makeGiteaClient(scope: "acme").fetchRegistrationToken()
        XCTAssertEqual(auth, "token gt", "Gitea uses 'token <value>', not Bearer")
    }

    func testGiteaErrorMapping() async {
        StubProtocol.handler = { _ in (401, Data("nope".utf8), [:]) }
        defer { StubProtocol.handler = nil }
        do {
            _ = try await makeGiteaClient(scope: "acme").fetchRegistrationToken()
            XCTFail("should throw")
        } catch let error as GiteaError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testGiteaCredentialsValidateInstance() {
        XCTAssertThrowsError(try GiteaCredentials.validate(instance: "gitea.example.com"))
        XCTAssertThrowsError(try GiteaCredentials.validate(instance: "https://gitea.example.com/api"))
        XCTAssertNoThrow(try GiteaCredentials.validate(instance: "https://gitea.example.com"))
        XCTAssertNoThrow(try GiteaCredentials.validate(instance: "http://192.168.8.8:3000"))
    }

    // MARK: GitHub forge mapping

    func testGitHubForgeMapsUnifiedSurface() async throws {
        let github = FakeGitHub()
        github.register(name: "kinhin-1", busy: true)
        github.queueDepth = 2
        github.queueRepos = ["acme/ios-app"]
        let forge = GitHubForge(
            credentials: .github(token: "t", scope: "acme/widgets"), labels: ["kinhin"], client: github)

        let runners = try await forge.runners()
        XCTAssertEqual(runners, [ForgeRunner(id: runners.first?.id ?? 0, name: "kinhin-1", busy: true)])
        let queued = try await forge.queuedJobs()
        XCTAssertEqual(queued.count, 2)
        XCTAssertEqual(queued.first?.repository, "acme/ios-app")
        XCTAssertEqual(forge.registrationURL(), "https://github.com/acme/widgets")
    }

    // MARK: Demand merging & assignment

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

    // MARK: Gitea bootstrap script

    func testGiteaRegistrationScriptSingleRunner() {
        let script = RunnerBootstrap.giteaRegistrationScript(
            instance: "https://gitea.example.com", token: "T", labels: ["macos:host"], name: "kinhin-1"
        )
        XCTAssertTrue(script.contains("--no-interactive"))
        XCTAssertTrue(script.contains("--instance https://gitea.example.com"))
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

    // MARK: Token-gated image provisioning

    func testImagePrepareFailsWithoutAnyPlatformToken() async {
        let preparer = ImagePreparer(tart: FakeTart(), ssh: FakeSSH())
        do {
            _ = try await preparer.run(ImagePreparer.Options(hasGitHubToken: false, hasGiteaToken: false))
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
        _ = try await preparer.run(ImagePreparer.Options(hasGitHubToken: true, hasGiteaToken: false))

        let script = ssh.scripts.joined(separator: "\n")
        XCTAssertTrue(script.contains("actions-runner-osx-arm64"), "GitHub agent baked when PAT exists")
        XCTAssertFalse(script.contains("gitea-runner"), "gitea runner skipped when no Gitea token")
    }

    func testImagePrepareBakesGiteaWhenTokenPresent() async throws {
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: FakeTart(), ssh: ssh)
        _ = try await preparer.run(ImagePreparer.Options(hasGitHubToken: false, hasGiteaToken: true))

        let script = ssh.scripts.joined(separator: "\n")
        XCTAssertFalse(script.contains("actions-runner-osx-arm64"), "GitHub agent skipped when no PAT")
        XCTAssertTrue(script.contains("gitea.com/gitea/runner/releases"), "gitea runner baked when token exists")
    }

    // MARK: Config gitea section

    func testConfigParsesGiteaSection() throws {
        let yaml = """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            gitea:
              instance: "https://gitea.example.com"
              scope: "acme"
              labels: ["macos:host"]
            """
        let cfg = try ConfigLoader.parse(yaml)
        XCTAssertEqual(cfg.gitea?.instance, "https://gitea.example.com")
        XCTAssertEqual(cfg.gitea?.scope, "acme")
        XCTAssertEqual(cfg.gitea?.labels, ["macos:host"])
    }

    func testConfigRejectsInvalidGiteaSection() {
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                repo: "acme/widgets"
                labels: ["self-hosted"]
                gitea:
                  scope: "acme"
                """), "missing instance must be rejected")
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                repo: "acme/widgets"
                labels: ["self-hosted"]
                gitea:
                  instance: "not a url"
                  scope: "acme"
                """), "non-URL instance must be rejected")
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                repo: "acme/widgets"
                labels: ["self-hosted"]
                gitea:
                  instance: "https://gitea.example.com"
                  scope: "a/b/c"
                """), "invalid scope must be rejected")
    }

    func testConfigWithoutGiteaSectionParsesCleanly() throws {
        let cfg = try ConfigLoader.parse("repo: \"acme/widgets\"\nlabels: [\"self-hosted\"]")
        XCTAssertNil(cfg.gitea)
    }

    // MARK: Version resolver

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
            return (200, Data("{\"tag_name\":\"v3.5.0\"}".utf8), [:])
        }
        defer { StubProtocol.handler = nil }

        let resolver = RunnerVersionResolver(session: URLSession(configuration: config))
        let versions = await resolver.resolve()
        XCTAssertEqual(versions.github, "2.337.0")
        XCTAssertEqual(versions.gitea, "3.5.0")
    }
}
