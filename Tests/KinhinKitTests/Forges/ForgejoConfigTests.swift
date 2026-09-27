import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The `forgejo:` top-level section (and `forge` forgejo accounts): parsing,
/// validation, the wire-compatible forge adapter, and engine attach.
final class ForgejoConfigTests: XCTestCase {
    func testParsesTopLevelForgejoSection() throws {
        let cfg = try ConfigLoader.parse(
            """
            repo: "acme/widgets"
            labels: [self-hosted]
            forgejo:
              instance: "https://code.example.com"
              scope: "acme/api"
              labels: [macos:host]
            """)
        let forgejo = try XCTUnwrap(cfg.forgejo)
        XCTAssertEqual(forgejo.instance, "https://code.example.com")
        XCTAssertEqual(forgejo.scope, "acme/api")
        XCTAssertEqual(forgejo.labels, ["macos:host"])
        XCTAssertTrue(ConfigLoader.hasAnyForge(cfg))
        // allAccounts carries the legacy forgejo account when configured.
        XCTAssertEqual(cfg.allAccounts.first(where: { $0.name == "forgejo" })?.scope, "acme/api")
    }

    func testForgejoSectionIsOptional() throws {
        let cfg = try ConfigLoader.parse("repo: \"acme/widgets\"\nlabels: [x]\n")
        XCTAssertNil(cfg.forgejo)
    }

    func testForgejoValidationMirrorsGitea() {
        XCTAssertThrowsError(
            try ConfigLoader.parse("repo: \"acme/widgets\"\nlabels: [x]\nforgejo:\n  scope: \"acme/api\"\n")
        ) { error in
            guard case .invalid(let message) = error as? ConfigError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("forgejo.instance"), message)
        }
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                "repo: \"acme/widgets\"\nlabels: [x]\nforgejo:\n  instance: \"https://code.example.com\"\n")
        ) { error in
            guard case .invalid(let message) = error as? ConfigError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("forgejo.scope"), message)
        }
        // Instance URL validation is shared with Gitea.
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                "repo: \"acme/widgets\"\nlabels: [x]\nforgejo:\n  instance: \"https://code.example.com/api\"\n  scope: \"acme\"\n"
            )
        ) { error in
            guard case .invalid(let message) = error as? ConfigError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("forgejo.instance must be a base URL"), message)
        }
    }

    func testForgejoAccountsEntryParses() throws {
        let cfg = try ConfigLoader.parse(
            """
            accounts:
              - name: code
                forge: forgejo
                scope: "acme/api"
                instance: "https://code.example.com"
            labels: [x]
            """)
        let account = try XCTUnwrap(cfg.accounts.first)
        XCTAssertEqual(account.forge, .forgejo)
        XCTAssertEqual(account.instance, "https://code.example.com")
    }

    func testEngineTokenSatisfiedByForgejoToken() throws {
        let cfg = try ConfigLoader.parse(
            """
            repo: "\(ConfigLoader.templateRepo)"
            labels: [x]
            forgejo:
              instance: "https://code.example.com"
              scope: "acme/api"
            """)
        XCTAssertNil(try ConfigLoader.engineToken(for: cfg, load: { _ in nil }))
        XCTAssertNotNil(
            try ConfigLoader.engineToken(for: cfg, load: { $0 == .forgejo ? "fj" : nil }),
            "a Forgejo token alone makes the config usable (Forgejo-only fleet)")
    }

    // MARK: The forge adapter

    private func makeStubbedForgejoForge() -> ForgejoForge {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = GiteaClient(
            credentials: GiteaCredentials(token: "fj", scope: "acme", instance: "https://code.example.com"),
            session: URLSession(configuration: config))
        return ForgejoForge(
            credentials: .forgejo(token: "fj", scope: "acme", instance: "https://code.example.com"),
            labels: ["macos:host"], client: client, registrationToken: "reg")
    }

    func testForgejoIdentityAndDemand() async throws {
        StubProtocol.handler = { request in
            if request.url?.query?.contains("status=waiting") == true {
                return (
                    200,
                    Data(
                        "{\"total_count\":1,\"entries\":[{\"id\":1,\"name\":\"build\",\"repo_full_name\":\"acme/api\"}]}"
                            .utf8),
                    [:]
                )
            }
            return (200, Data("{\"total_count\":0,\"runners\":[]}".utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let forge = makeStubbedForgejoForge()
        XCTAssertEqual(forge.id, .forgejo)
        XCTAssertEqual(forge.name, "forgejo")
        XCTAssertEqual(forge.account, "forgejo")
        XCTAssertEqual(forge.registrationURL(), "https://code.example.com")
        let jobs = try await forge.queuedJobs()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.repository, "acme/api")
        // The bootstrap script is the Gitea flavor with the Forgejo instance.
        let script = try await TartRuntime(tart: FakeTart(), bootTimeout: { 300 }).registrationScript(
            forge: forge, token: "reg", name: "kinhin-1", runnerCount: 1,
            route: RepoRoute(repo: "acme", image: "img", ephemeral: true, bootTimeout: 300), labels: nil)
        XCTAssertTrue(script.contains("--instance 'https://code.example.com'"))
    }

    // MARK: Registration on every runtime

    /// Forgejo used to fail registration: the engine and the runtimes cast
    /// the forge to `GiteaForge`, which a `ForgejoForge` is not.
    func testForgejoRegistersWithTheGiteaFamilyFlow() async throws {
        let forge = makeStubbedForgejoForge()
        XCTAssertEqual(forge.registration, .sharedLongLived)
        XCTAssertEqual(forge.exitSemantics, .idleGrace)
        let token = try await forge.mintRegistrationToken()
        XCTAssertEqual(token, "reg")

        let route = RepoRoute(repo: "acme", image: "img", ephemeral: true, bootTimeout: 300)
        let docker = DockerRuntime(shell: FakeShell(), image: "img", cpus: 2, memoryGB: 4)
        let script = try await docker.registrationScript(
            forge: forge, token: token, name: "kinhin-1", runnerCount: 1, route: route, labels: nil)
        XCTAssertTrue(script.contains("https://code.example.com"))
        XCTAssertTrue(script.contains("reg"))
    }
}
