import XCTest

@testable import KinhinKit

final class TokenRequirementsTests: XCTestCase {
    func testGitHubOrgScopeNamesTheOrgRunnerPermission() {
        let text = TokenRequirements.github(scope: "acme").plainText
        XCTAssertTrue(text.contains("organization 'acme'"), text)
        XCTAssertTrue(text.contains("Self-hosted runners: Read and write"), text)
        XCTAssertTrue(text.contains("Actions: Read-only"), text)
        XCTAssertTrue(text.contains("admin:org, repo"), "classic scopes for an org: \(text)")
        XCTAssertFalse(text.contains("Administration"), "repo-only permission must not leak into org advice")
    }

    func testGitHubRepoScopeNamesTheRepoPermissions() {
        let text = TokenRequirements.github(scope: "acme/api").plainText
        XCTAssertTrue(text.contains("repository 'acme/api'"), text)
        XCTAssertTrue(text.contains("Administration: Read and write"), text)
        XCTAssertTrue(text.contains("Scope: repo"), text)
        XCTAssertFalse(text.contains("admin:org"), "org advice must not leak into repo advice")
    }

    func testUnknownGitHubScopeListsBothCases() {
        for scope in ["", "  ", ConfigLoader.templateRepo] {
            let text = TokenRequirements.github(scope: scope).plainText
            XCTAssertTrue(text.contains("one repository"), text)
            XCTAssertTrue(text.contains("whole organization"), text)
        }
    }

    func testGiteaScopesFollowTheScope() {
        let repo = TokenRequirements.gitea(scope: "team/repo", instance: "https://git.example.com/").plainText
        XCTAssertTrue(repo.contains("write:repository"), repo)
        XCTAssertFalse(repo.contains("write:organization"), repo)
        XCTAssertTrue(repo.contains("https://git.example.com/user/settings/applications"), repo)

        let org = TokenRequirements.gitea(scope: "team").plainText
        XCTAssertTrue(org.contains("write:organization"), org)
        XCTAssertTrue(org.contains("read:repository"), org)
        XCTAssertTrue(org.contains("must own"), "token owner rights are called out: \(org)")
    }

    func testSummaryIsACompactOneLiner() {
        let summary = TokenRequirements.github(scope: "acme").summary
        XCTAssertFalse(summary.contains("\n"))
        XCTAssertTrue(summary.hasPrefix("Fine-grained token:"), summary)
    }
}
