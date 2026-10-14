import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// A hot config reload hands every forge the reloaded label sets; each forge
/// swaps in whichever set its demand or running query filters by, and forges
/// that filter by neither stay as they are (`Forge.relabeled`).
final class ForgeRelabelTests: XCTestCase {
    private func client() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    func testGitHubFiltersByTheFleetLabels() throws {
        let forge = GitHubForge(
            credentials: .github(token: "t", scope: "acme/w"), labels: ["old"], client: FakeGitHub())
        let reloaded = try XCTUnwrap(
            forge.relabeled(fleetLabels: ["new"], servedLabels: ["pool"]) as? GitHubForge)
        XCTAssertEqual(reloaded.labels, ["new"], "demand and attribution follow the fleet's labels")
        XCTAssertEqual(reloaded.account, forge.account)
    }

    func testGiteaFiltersByTheServedLabels() throws {
        let gitea = GiteaClient(
            credentials: GiteaCredentials(token: "t", scope: "acme/api", instance: "https://gitea.example.com"),
            session: client())
        let forge = GiteaForge(
            credentials: .gitea(token: "t", scope: "acme/api", instance: "https://gitea.example.com"),
            labels: ["own"], client: gitea, registrationToken: "gt")
        let reloaded = try XCTUnwrap(
            forge.relabeled(fleetLabels: ["fleet"], servedLabels: ["pool-a", "pool-b"]) as? GiteaForge)
        XCTAssertEqual(reloaded.poolLabels, ["pool-a", "pool-b"])
        XCTAssertEqual(reloaded.labels, ["own"], "the account's own labels only change with an engine rebuild")
    }

    func testGitLabFiltersByTheServedLabels() throws {
        let gitlab = GitLabClient(
            credentials: GitLabCredentials(token: "t", scope: "acme/api", instance: "https://gitlab.example.com"),
            session: client())
        let forge = GitLabForge(
            credentials: .gitlab(token: "t", scope: "acme/api", instance: "https://gitlab.example.com"),
            labels: ["own"], client: gitlab, scope: .project(id: 7, path: "acme/api"), runnerListTTL: 0)
        let reloaded = try XCTUnwrap(
            forge.relabeled(fleetLabels: ["fleet"], servedLabels: ["pool-a"]) as? GitLabForge)
        XCTAssertEqual(reloaded.poolLabels, ["pool-a"])
        XCTAssertEqual(reloaded.labels, ["own"])
    }
}
