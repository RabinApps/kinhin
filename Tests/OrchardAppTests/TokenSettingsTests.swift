import XCTest
import OrchardKit
@testable import orchard_app
@testable import OrchardKit

/// The token settings form's per-provider card content: stored/missing state,
/// masked Keychain prefix, and the config-aware status lines (a Gitea card
/// without a `gitea:` section must say so instead of implying the token is in
/// use). Pure logic — no AppKit state is exercised here.
final class TokenSettingsTests: XCTestCase {
    private var giteaConfig: OrchardConfig.GiteaForgeConfig {
        OrchardConfig.GiteaForgeConfig(instance: "https://gitea.example.com", scope: "acme", labels: ["macos:host"])
    }

    // MARK: GitHub

    func testGitHubStoredRowMasksTokenAndCarriesScope() {
        let row = TokenSettingsRow.make(forge: .github, token: "ghp_secret1234", repo: "acme/widgets", gitea: nil)
        XCTAssertEqual(row.title, "GitHub")
        XCTAssertTrue(row.configured)
        XCTAssertEqual(row.buttonTitle, "Replace…")
        XCTAssertFalse(row.status.contains("secret"), "the status line must never leak the token")
        XCTAssertTrue(row.status.contains("ghp_…"), "only the 4-character masked prefix is shown")
        XCTAssertTrue(row.status.contains("acme/widgets"))
        XCTAssertTrue(row.status.contains("Stored in Keychain"))
    }

    func testGitHubMissingRowOffersSave() {
        let row = TokenSettingsRow.make(forge: .github, token: nil, repo: "acme/widgets", gitea: nil)
        XCTAssertEqual(row.buttonTitle, "Save…")
        XCTAssertTrue(row.status.contains("Not stored"))
        XCTAssertTrue(row.status.contains("acme/widgets"))
    }

    // MARK: Gitea

    func testGiteaStoredWithConfigShowsInstanceAndScope() {
        let row = TokenSettingsRow.make(forge: .gitea, token: "gt_token_9999", repo: "acme/widgets", gitea: giteaConfig)
        XCTAssertEqual(row.title, "Gitea")
        XCTAssertTrue(row.configured)
        XCTAssertEqual(row.buttonTitle, "Replace…")
        XCTAssertFalse(row.status.contains("token_9999"), "the status line must never leak the token")
        XCTAssertTrue(row.status.contains("gt_t…"))
        XCTAssertTrue(row.status.contains("acme @ https://gitea.example.com"))
    }

    func testGiteaMissingWithConfigShowsEnterHint() {
        let row = TokenSettingsRow.make(forge: .gitea, token: nil, repo: nil, gitea: giteaConfig)
        XCTAssertEqual(row.buttonTitle, "Save…")
        XCTAssertTrue(row.status.contains("Not stored"))
        XCTAssertTrue(row.status.contains("https://gitea.example.com"))
    }

    /// A token stored before the config declares gitea: stays replaceable —
    /// the card must say it is kept but not in use.
    func testGiteaStoredWithoutConfigSaysNotInUse() {
        let row = TokenSettingsRow.make(forge: .gitea, token: "gt_x", repo: "acme/widgets", gitea: nil)
        XCTAssertFalse(row.configured, "no gitea: section → the token is not in use")
        XCTAssertTrue(row.status.contains("Stored in Keychain"))
        XCTAssertTrue(row.status.contains("no gitea: section"))
        XCTAssertFalse(row.status.contains("acme/widgets"), "unconfigured Gitea must not borrow the GitHub scope")
    }

    func testGiteaMissingWithoutConfigSaysNotInUse() {
        let row = TokenSettingsRow.make(forge: .gitea, token: nil, repo: nil, gitea: nil)
        XCTAssertFalse(row.configured)
        XCTAssertTrue(row.status.contains("Not in use"))
        XCTAssertTrue(row.status.contains("gitea:"))
    }

    // MARK: Coverage

    func testEveryForgeProducesARow() {
        let rows = ForgeID.allCases.map {
            TokenSettingsRow.make(forge: $0, token: nil, repo: nil, gitea: nil)
        }
        XCTAssertEqual(rows.count, ForgeID.allCases.count, "the form renders one card per provider")
        XCTAssertEqual(Set(rows.map(\.title)).count, ForgeID.allCases.count, "card titles are distinct")
    }

    // MARK: Token health check (the cards' Check buttons)

    /// Recording GitHub double — the probe must go through the same
    /// GitHubServing surface the engine uses.
    private final class RecordingGitHub: GitHubServing, @unchecked Sendable {
        var configureURL = "https://github.com/acme/widgets"
        var asked = 0
        var error: GitHubError?
        func fetchRegistrationToken() async throws -> RegistrationToken {
            asked += 1
            if let error { throw error }
            return RegistrationToken(token: "lrt", expiresAt: Date().addingTimeInterval(3600))
        }
        func listRunners() async throws -> [GHRunner] { [] }
        func deleteRunner(id: Int) async throws {}
        func queuedJobs(matching labels: Set<String>) async throws -> [QueuedJob] { [] }
        func runningJobs(matching labels: Set<String>) async throws -> [RunningJob] { [] }
    }

    private func giteaClient() -> GiteaClient {
        // Real client pointed at an unroutable instance: the failure path
        // surfaces the transport error without touching the network beyond
        // the local loopback.
        GiteaClient(credentials: GiteaCredentials(token: "gt", scope: "acme", instance: "http://127.0.0.1:1"))
    }

    private static func configWithRepo(_ repo: String) -> OrchardConfig {
        var cfg = OrchardConfig.default
        cfg.repo = repo
        return cfg
    }

    func testGitHubCheckSuccessThroughInjectedClient() async {
        let client = RecordingGitHub()
        let report = await TokenHealthCheck.check(
            forge: .github,
            config: Self.configWithRepo("acme/widgets"),
            keychainToken: { _ in "ghp_x" },
            github: client
        )
        XCTAssertEqual(client.asked, 1, "the check must probe via the forge API")
        XCTAssertTrue(report.ok)
        XCTAssertTrue(report.message.contains("Token works"))
    }

    func testGitHubCheckWithoutTokenAsksToSaveFirst() async {
        let report = await TokenHealthCheck.check(
            forge: .github,
            config: Self.configWithRepo("acme/widgets"),
            keychainToken: { _ in nil }
        )
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.message.contains("No token stored"))
    }

    func testGitHubCheckWithoutScopeIsNotCheckable() async {
        let report = await TokenHealthCheck.check(
            forge: .github,
            config: Self.configWithRepo(""),
            keychainToken: { _ in "ghp_x" }
        )
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.message.contains("No scope to check"))
    }

    func testGiteaCheckWithoutConfigSectionIsNotCheckable() async {
        let report = await TokenHealthCheck.check(
            forge: .gitea,
            config: Self.configWithRepo("acme/widgets"),
            keychainToken: { _ in "gt_x" }
        )
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.message.contains("gitea:"))
    }

    func testGiteaCheckFailureSurfacesProbeError() async {
        let report = await TokenHealthCheck.gitea(
            token: "gt_bad",
            config: OrchardConfig.GiteaForgeConfig(instance: "http://127.0.0.1:1", scope: "acme"),
            client: giteaClient()
        )
        XCTAssertFalse(report.ok, "an unroutable instance cannot validate the token")
        XCTAssertTrue(report.message.contains("Token check failed"))
    }

    /// The form's typed-token override must reach the probe (checking a
    /// bad paste before saving is the point of the override).
    func testTypedTokenOverridesKeychainForTheCheck() async {
        var overrideSeen = false
        let report = await TokenHealthCheck.check(
            forge: .github,
            config: Self.configWithRepo("acme/widgets"),
            keychainToken: { _ in
                overrideSeen = true
                return "stored"
            },
            github: RecordingGitHub()
        )
        XCTAssertTrue(report.ok)
        XCTAssertTrue(overrideSeen, "the probe consulted the injected token source")
    }
}
