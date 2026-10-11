import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// A job is trusted only when its forge proved it is not a fork's PR. GitHub
/// scale-set messages and the Gitea/Forgejo queues do not say, so their jobs
/// get the fork treatment: no shared cache, and no repo file from the PR branch.
final class UntrustedJobTests: XCTestCase {
    private let project = KinhinConfig.ProjectConfig(pattern: "acme/*", repoFile: true, shareCache: true)

    func testOnlyAProvenNonForkIsTrusted() {
        XCTAssertFalse(
            ForgeJob(name: "j", runnerName: nil, repository: "a/b", isFork: false, forkKnown: true).isUntrusted)
        XCTAssertTrue(
            ForgeJob(name: "j", runnerName: nil, repository: "a/b", isFork: true, forkKnown: true).isUntrusted)
        XCTAssertTrue(ForgeJob(name: "j", runnerName: nil, repository: "a/b").isUntrusted, "origin unknown")
    }

    func testAJobOfUnknownOriginGetsNoSharedCacheAndReadsTheDefaultBranch() async throws {
        let github = FakeGitHub()
        github.projectFiles["acme/api@default"] = Data("toolchains:\n  specs: [go@1.22.5]\n".utf8)
        let job = ForgeJob(name: "j", runnerName: nil, repository: "acme/api", ref: "pr-branch", sha: "abc123")

        let resolution = try await ProjectToolchainSource().resolve(job: job, forge: github, projects: [project])

        XCTAssertFalse(resolution.shareCache, "share_cache: true is not honored for a job that may be a fork's")
        XCTAssertEqual(github.projectFileCalls, ["acme/api@default"])
        XCTAssertEqual(resolution.toolchains?.specs, ["go@1.22.5"])
    }

    func testAProvenNonForkKeepsTheSharedCache() async throws {
        let github = FakeGitHub()
        github.projectFiles["acme/api@abc123"] = Data("toolchains:\n  specs: [go@1.22.5]\n".utf8)
        let job = ForgeJob(
            name: "j", runnerName: nil, repository: "acme/api", ref: "main", sha: "abc123", isFork: false,
            forkKnown: true)

        let resolution = try await ProjectToolchainSource().resolve(job: job, forge: github, projects: [project])

        XCTAssertTrue(resolution.shareCache)
        XCTAssertEqual(github.projectFileCalls, ["acme/api@abc123"])
    }

    func testGitHubRunsKnowTheirOriginOnlyWhenBothRepositoriesAreNamed() throws {
        func run(_ json: String) throws -> GitHubClient.RunRef {
            let summary = try JSONDecoder().decode(GitHubClient.RunSummary.self, from: Data(json.utf8))
            return GitHubClient.RunRef(summary: summary, repository: nil)
        }
        let fork = try run(
            #"{"id":1,"repository":{"full_name":"acme/api"},"head_repository":{"full_name":"eve/api"}}"#)
        XCTAssertTrue(fork.isFork)
        XCTAssertTrue(fork.forkKnown)
        let unknown = try run(#"{"id":2,"repository":{"full_name":"acme/api"}}"#)
        XCTAssertFalse(unknown.forkKnown, "no head repository: the origin is not known")
    }
}
