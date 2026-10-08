import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport
@testable import kinhin_app

/// The forge token health check: probes the stored (or just-typed) token
/// against the forge API and reports a user-readable verdict. Pure logic —
/// no AppKit state is exercised here.
final class TokenHealthCheckTests: XCTestCase {
    // MARK: - Token health check

    private func giteaClient() -> GiteaClient {
        // Real client pointed at an unroutable instance: the failure path
        // surfaces the transport error without touching the network beyond
        // the local loopback.
        GiteaClient(credentials: GiteaCredentials(token: "gt", scope: "acme", instance: "http://127.0.0.1:1"))
    }

    private static func configWithRepo(_ repo: String) -> KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.accounts = repo.isEmpty ? [] : [AccountConfig(name: "github", forge: .github, scope: repo)]
        return cfg
    }

    func testGitHubCheckSuccessThroughInjectedClient() async {
        let client = FakeGitHub()
        let report = await TokenHealthCheck.check(
            forge: .github,
            config: Self.configWithRepo("acme/widgets"),
            keychainToken: { _, _ in "ghp_x" },
            admin: { account, token in GitHubDescriptor().makeAdmin(account: account, token: token, client: client) }
        )
        XCTAssertEqual(client.registrationTokenCalls, 1, "the check must probe via the forge API")
        XCTAssertTrue(report.ok)
        XCTAssertTrue(report.message.contains("Token works"))
    }

    func testGitHubCheckWithoutTokenAsksToSaveFirst() async {
        let report = await TokenHealthCheck.check(
            forge: .github,
            config: Self.configWithRepo("acme/widgets"),
            keychainToken: { _, _ in nil }
        )
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.message.contains("No token stored"))
    }

    func testGitHubCheckWithoutScopeIsNotCheckable() async {
        let report = await TokenHealthCheck.check(
            forge: .github,
            config: Self.configWithRepo(""),
            keychainToken: { _, _ in "ghp_x" }
        )
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.message.contains("No scope to check"))
    }

    func testGiteaCheckWithoutConfigAccountIsNotCheckable() async {
        let report = await TokenHealthCheck.check(
            forge: .gitea,
            config: Self.configWithRepo("acme/widgets"),
            keychainToken: { _, _ in "gt_x" }
        )
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.message.contains("gitea account"))
    }

    func testGiteaCheckFailureSurfacesProbeError() async {
        let report = await TokenHealthCheck.gitea(
            token: "gt_bad", scope: "acme", instance: "http://127.0.0.1:1", client: giteaClient())
        XCTAssertFalse(report.ok, "an unroutable instance cannot validate the token")
        XCTAssertTrue(report.message.contains("Token check failed"))
    }

    /// A typed token override must reach the probe (checking a bad paste
    /// before saving is the point of the override).
    func testTypedTokenOverridesKeychainForTheCheck() async {
        var overrideSeen = false
        let report = await TokenHealthCheck.check(
            forge: .github,
            config: Self.configWithRepo("acme/widgets"),
            keychainToken: { _, _ in
                overrideSeen = true
                return "stored"
            },
            admin: { account, token in
                GitHubDescriptor().makeAdmin(account: account, token: token, client: FakeGitHub())
            }
        )
        XCTAssertTrue(report.ok)
        XCTAssertTrue(overrideSeen, "the probe consulted the injected token source")
    }
}
