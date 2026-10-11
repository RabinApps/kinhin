import Foundation
import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Content-cache behavior of `ProjectToolchainSource`: the engine caches each
/// repo-file read per (forge account, repository, sha-or-ref), so a queue of
/// jobs for one commit costs a single API call per forge, and a fork's PR
/// reads the base repository's default-branch file, never the fork's own.
/// These tests run the same scenarios against every file-capable forge so the
/// cache contract is shared (GitHub, Gitea, GitLab), not GitHub-only.
final class ProjectToolchainSourceTests: XCTestCase {
    private let goFile = Data("toolchains:\n  specs: [go@1.22.5]\n".utf8)
    private let nodeFile = Data("toolchains:\n  specs: [node@22]\n".utf8)

    /// A repo-file-enabled project covering `acme/api`.
    private func projectConfig() -> KinhinConfig.ProjectConfig {
        KinhinConfig.ProjectConfig(pattern: "acme/api", repoFile: true)
    }

    // MARK: - GitHub

    func testFileReadsAreCachedPerSha_github() async throws {
        let github = FakeGitHub()
        github.projectFiles["acme/api@abc123"] = goFile
        let source = ProjectToolchainSource()
        let project = projectConfig()
        try await assertResolution(
            source: source, forge: github, project: project,
            job: ForgeJob(
                name: "j1", runnerName: nil, repository: "acme/api", sha: "abc123", isFork: false, forkKnown: true),
            expectedToolchains: .init(specs: ["go@1.22.5"]), expectedSource: .repoFile)
        try await assertResolution(
            source: source, forge: github, project: project,
            job: ForgeJob(
                name: "j2", runnerName: nil, repository: "acme/api", sha: "abc123", isFork: false, forkKnown: true),
            expectedToolchains: .init(specs: ["go@1.22.5"]), expectedSource: .repoFile)
        XCTAssertEqual(github.projectFileCalls, ["acme/api@abc123"], "second job reuses the cached read")
    }

    func testForkJobsReadTheDefaultBranchFile_github() async throws {
        let github = FakeGitHub()
        github.projectFiles["acme/api@default"] = goFile
        github.projectFiles["acme/api@abc123"] = nodeFile
        let source = ProjectToolchainSource()
        let project = projectConfig()
        try await assertResolution(
            source: source, forge: github, project: project,
            job: ForgeJob(
                name: "j1", runnerName: nil, repository: "acme/api", ref: "feature/x", sha: "abc123", isFork: true),
            expectedToolchains: .init(specs: ["go@1.22.5"]), expectedSource: .repoFile)
        XCTAssertEqual(
            github.projectFileCalls, ["acme/api@default"],
            "a fork reads the base repo's default branch, never its own sha")
    }

    // MARK: - Gitea

    func testFileReadsAreCachedPerSha_gitea() async throws {
        let gitea = FakeGitea()
        gitea.projectFiles["acme/api@abc123"] = goFile
        let source = ProjectToolchainSource()
        let project = projectConfig()
        try await assertResolution(
            source: source, forge: gitea, project: project,
            job: ForgeJob(
                name: "j1", runnerName: nil, repository: "acme/api", sha: "abc123", isFork: false, forkKnown: true),
            expectedToolchains: .init(specs: ["go@1.22.5"]), expectedSource: .repoFile)
        try await assertResolution(
            source: source, forge: gitea, project: project,
            job: ForgeJob(
                name: "j2", runnerName: nil, repository: "acme/api", sha: "abc123", isFork: false, forkKnown: true),
            expectedToolchains: .init(specs: ["go@1.22.5"]), expectedSource: .repoFile)
        XCTAssertEqual(gitea.projectFileCalls, ["acme/api@abc123"], "second job reuses the cached read")
    }

    func testForkJobsReadTheDefaultBranchFile_gitea() async throws {
        let gitea = FakeGitea()
        gitea.projectFiles["acme/api@default"] = goFile
        gitea.projectFiles["acme/api@abc123"] = nodeFile
        let source = ProjectToolchainSource()
        let project = projectConfig()
        try await assertResolution(
            source: source, forge: gitea, project: project,
            job: ForgeJob(
                name: "j1", runnerName: nil, repository: "acme/api", ref: "feature/x", sha: "abc123", isFork: true),
            expectedToolchains: .init(specs: ["go@1.22.5"]), expectedSource: .repoFile)
        XCTAssertEqual(
            gitea.projectFileCalls, ["acme/api@default"],
            "a fork reads the base repo's default branch, never its own sha")
    }

    // MARK: - GitLab

    func testFileReadsAreCachedPerSha_gitlab() async throws {
        let gitlab = FakeGitLab()
        gitlab.projectFiles["acme/api@abc123"] = goFile
        let source = ProjectToolchainSource()
        let project = projectConfig()
        try await assertResolution(
            source: source, forge: gitlab, project: project,
            job: ForgeJob(
                name: "j1", runnerName: nil, repository: "acme/api", sha: "abc123", isFork: false, forkKnown: true),
            expectedToolchains: .init(specs: ["go@1.22.5"]), expectedSource: .repoFile)
        try await assertResolution(
            source: source, forge: gitlab, project: project,
            job: ForgeJob(
                name: "j2", runnerName: nil, repository: "acme/api", sha: "abc123", isFork: false, forkKnown: true),
            expectedToolchains: .init(specs: ["go@1.22.5"]), expectedSource: .repoFile)
        XCTAssertEqual(gitlab.projectFileCalls, ["acme/api@abc123"], "second job reuses the cached read")
    }

    func testForkJobsReadTheDefaultBranchFile_gitlab() async throws {
        let gitlab = FakeGitLab()
        gitlab.projectFiles["acme/api@default"] = goFile
        gitlab.projectFiles["acme/api@abc123"] = nodeFile
        let source = ProjectToolchainSource()
        let project = projectConfig()
        try await assertResolution(
            source: source, forge: gitlab, project: project,
            job: ForgeJob(
                name: "j1", runnerName: nil, repository: "acme/api", ref: "feature/x", sha: "abc123", isFork: true),
            expectedToolchains: .init(specs: ["go@1.22.5"]), expectedSource: .repoFile)
        XCTAssertEqual(
            gitlab.projectFileCalls, ["acme/api@default"],
            "a fork reads the base repo's default branch, never its own sha")
    }

    // MARK: - Branch-TTL behavior

    func testBranchReadsExpireWhileShaReadsStayPermanent_github() async throws {
        let github = FakeGitHub()
        // Seed the branch file at the key the fake will be called with
        // (repository@ref), and a sha-scoped file separately.
        github.projectFiles["acme/api@main"] = goFile
        github.projectFiles["acme/api@abc123"] = nodeFile
        let clock = IncrementingClock(increment: ProjectToolchainSource.branchTTL + 1)
        let source = ProjectToolchainSource(now: { clock.now })
        let project = projectConfig()
        // First read: branch-only (no sha) → cached as non-permanent.
        let r1 = try await source.resolve(
            job: ForgeJob(
                name: "j1", runnerName: nil, repository: "acme/api", ref: "main", sha: nil, isFork: false,
                forkKnown: true),
            forge: github, projects: [project])
        XCTAssertEqual(r1.toolchains?.specs, ["go@1.22.5"])
        XCTAssertEqual(github.projectFileCalls, ["acme/api@main"])

        // Same branch re-read after TTL → re-fetched (non-permanent entry expired).
        let r2 = try await source.resolve(
            job: ForgeJob(
                name: "j2", runnerName: nil, repository: "acme/api", ref: "main", sha: nil, isFork: false,
                forkKnown: true),
            forge: github, projects: [project])
        XCTAssertEqual(r2.toolchains?.specs, ["go@1.22.5"])
        XCTAssertEqual(github.projectFileCalls, ["acme/api@main", "acme/api@main"], "after TTL: re-reads the branch")

        // A sha-scoped read is permanent and never expires.
        let r3 = try await source.resolve(
            job: ForgeJob(
                name: "j3", runnerName: nil, repository: "acme/api", ref: "main", sha: "abc123", isFork: false,
                forkKnown: true),
            forge: github, projects: [project])
        XCTAssertEqual(r3.toolchains?.specs, ["node@22"])
        XCTAssertEqual(github.projectFileCalls, ["acme/api@main", "acme/api@main", "acme/api@abc123"])

        // Re-read the same sha later: still cached (permanent entry never expires).
        let r4 = try await source.resolve(
            job: ForgeJob(
                name: "j4", runnerName: nil, repository: "acme/api", ref: "main", sha: "abc123", isFork: false,
                forkKnown: true),
            forge: github, projects: [project])
        XCTAssertEqual(r4.toolchains?.specs, ["node@22"])
        XCTAssertEqual(
            github.projectFileCalls, ["acme/api@main", "acme/api@main", "acme/api@abc123"],
            "permanent sha entry never expires")
    }

    // MARK: - Helpers

    /// Resolves `job` and asserts the toolchain selection + source, then
    /// returns the resolution so callers can further assert warnings etc.
    private func assertResolution<F: Forge>(
        source: ProjectToolchainSource, forge: F, project: KinhinConfig.ProjectConfig,
        job: ForgeJob,
        expectedToolchains: KinhinConfig.ToolchainsConfig, expectedSource: ProjectResolution.Source
    ) async throws -> ProjectResolution {
        let resolution = await source.resolve(job: job, forge: forge, projects: [project])
        XCTAssertEqual(
            resolution.toolchains?.specs, expectedToolchains.specs, "toolchains: \(resolution.toolchains?.specs ?? [])")
        XCTAssertEqual(resolution.source, expectedSource, "source: \(resolution.source)")
        return resolution
    }
}

/// A trivial clock whose `now` advances by a fixed increment on each call.
private final class IncrementingClock: Sendable {
    private let increment: TimeInterval
    private let value: Mutex<TimeInterval>

    init(increment: TimeInterval, start: TimeInterval = 0) {
        self.increment = increment
        self.value = Mutex(start)
    }

    var now: Date {
        value.withLock { $0 += increment }
        return Date(timeIntervalSince1970: value.withLock { $0 })
    }
}
