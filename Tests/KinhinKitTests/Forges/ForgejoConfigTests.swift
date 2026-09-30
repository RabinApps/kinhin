import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Forgejo accounts: parsing, validation, the wire-compatible forge adapter,
/// and engine attach.
final class ForgejoConfigTests: XCTestCase {
    func testParsesForgejoAccount() throws {
        let cfg = try ConfigLoader.parse(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
              - name: forgejo
                forge: forgejo
                instance: "https://code.example.com"
                scope: "acme/api"
                labels: [macos:host]
            labels: [self-hosted]
            """)
        let forgejo = try XCTUnwrap(cfg.forgejo)
        XCTAssertEqual(forgejo.instance, "https://code.example.com")
        XCTAssertEqual(forgejo.scope, "acme/api")
        XCTAssertEqual(forgejo.labels, ["macos:host"])
        XCTAssertTrue(ConfigLoader.hasAnyForge(cfg))
        XCTAssertEqual(cfg.allAccounts.first(where: { $0.name == "forgejo" })?.scope, "acme/api")
    }

    func testForgejoSectionIsOptional() throws {
        let cfg = try ConfigLoader.parse(
            "accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\nlabels: [x]\n")
        XCTAssertNil(cfg.forgejo)
    }

    func testForgejoAccountValidation() {
        let cases: [(String, String)] = [
            ("- {name: fj, forge: forgejo, scope: acme/api}", "instance is required"),
            (
                "- {name: fj, forge: forgejo, scope: acme/api, instance: 'https://code.example.com/api'}",
                "instance must be a base URL"
            ),
            ("- {name: fj, forge: forgejo, scope: x/y/z, instance: 'https://code.example.com'}", "scope must be"),
        ]
        for (entry, expected) in cases {
            XCTAssertThrowsError(
                try ConfigLoader.parse("labels: [x]\naccounts:\n  \(entry)\n"), entry
            ) { error in
                XCTAssertTrue("\(error.localizedDescription)".contains(expected), "\(entry): \(error)")
            }
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
            accounts:
              - name: forgejo
                forge: forgejo
                instance: "https://code.example.com"
                scope: "acme/api"
            labels: [x]
            """)
        XCTAssertNil(try ConfigLoader.engineToken(for: cfg, loadAccount: { _, _ in nil }))
        XCTAssertNotNil(
            try ConfigLoader.engineToken(for: cfg, loadAccount: { forge, _ in forge == .forgejo ? "fj" : nil }),
            "a Forgejo token alone makes the config usable (Forgejo-only fleet)")
    }

    // MARK: - The forge adapter

    private func makeStubbedForgejoForge() -> GiteaForge {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = GiteaClient(
            credentials: GiteaCredentials(token: "fj", scope: "acme", instance: "https://code.example.com"),
            session: URLSession(configuration: config))
        return GiteaForge(
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
            return (200, Data("{\"total_count\":0,\"entries\":[]}".utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let forge = makeStubbedForgejoForge()
        XCTAssertEqual(forge.id, .forgejo)
        XCTAssertEqual(forge.name, "forgejo")
        XCTAssertEqual(forge.account, "forgejo", "the default account is the forge's conventional name")
        XCTAssertEqual(forge.registrationURL(), "https://code.example.com")
        XCTAssertTrue(forge.attributesByRepo, "repo attribution mirrors gitea-runner's job labels")
    }
}
