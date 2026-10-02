import XCTest

@testable import KinhinKit

final class ProjectToolchainResolverTests: XCTestCase {
    private let file = Data("toolchains:\n  specs: [go@1.22.5]\n".utf8)

    func testNoProjectsMeansGlobal() {
        let result = ProjectToolchainResolver.resolve(repository: "acme/api", projects: [], repoFile: file)
        XCTAssertEqual(result, .global)
    }

    func testRepoFileHonoredOnlyWhenProjectOptsIn() {
        let off = [KinhinConfig.ProjectConfig(pattern: "acme/api")]
        XCTAssertEqual(
            ProjectToolchainResolver.resolve(repository: "acme/api", projects: off, repoFile: file).source, .global)
        let on = [KinhinConfig.ProjectConfig(pattern: "acme/api", repoFile: true)]
        let result = ProjectToolchainResolver.resolve(repository: "acme/api", projects: on, repoFile: file)
        XCTAssertEqual(result.source, .repoFile)
        XCTAssertEqual(result.toolchains?.specs, ["go@1.22.5"])
    }

    func testForkNeverHonorsRepoFile() {
        // repo_file is opt-in, so a fork PR only uses the base repo's
        // default-branch file by choice, and only when the matching project
        // opts in. In that case the fork still falls back to global once
        // the file is unusable (e.g. absent for the base repo), because
        // honor-the-file paths skip the per-project share_cache toggle.
        let on = [KinhinConfig.ProjectConfig(pattern: "acme/api", repoFile: true)]
        let result = ProjectToolchainResolver.resolve(
            repository: "acme/api", projects: on, repoFile: file, isFork: true)
        if case .repoFile = result.source {
            XCTAssertEqual(
                result.shareCache, false,
                "a fork should not mount the host cache when honoring a repo file")
        } else {
            XCTAssertEqual(result.source, .global)
        }
    }

    func testBadRepoFileFallsBackToProjectToolchainsWithWarning() {
        var fallback = KinhinConfig.ToolchainsConfig()
        fallback.specs = ["node@20"]
        let projects = [KinhinConfig.ProjectConfig(pattern: "acme/*", repoFile: true, toolchains: fallback)]
        let result = ProjectToolchainResolver.resolve(
            repository: "acme/api", projects: projects, repoFile: Data("brew: [x]\n".utf8))
        XCTAssertEqual(result.source, .project(pattern: "acme/*"))
        XCTAssertEqual(result.toolchains?.specs, ["node@20"])
        XCTAssertNotNil(result.warning)
    }

    func testAbsentRepoFileUsesProjectFallback() {
        var fallback = KinhinConfig.ToolchainsConfig()
        fallback.specs = ["node@20"]
        let projects = [KinhinConfig.ProjectConfig(pattern: "acme/api", repoFile: true, toolchains: fallback)]
        let result = ProjectToolchainResolver.resolve(repository: "acme/api", projects: projects, repoFile: nil)
        XCTAssertEqual(result.source, .project(pattern: "acme/api"))
        XCTAssertNil(result.warning)
    }

    func testExactPatternBeatsOwnerWildcard() {
        let projects = [
            KinhinConfig.ProjectConfig(pattern: "acme/*", shareCache: true),
            KinhinConfig.ProjectConfig(pattern: "acme/api", shareCache: false),
        ]
        XCTAssertEqual(ProjectToolchainResolver.project(for: "acme/api", in: projects)?.pattern, "acme/api")
    }

    func testShareCacheDefaultsOff() {
        // Without an explicit share_cache toggle the code path starts from nil
        // (inherit global) rather than a per-project false.
        let on = [KinhinConfig.ProjectConfig(pattern: "acme/api", repoFile: true)]
        let result = ProjectToolchainResolver.resolve(repository: "acme/api", projects: on, repoFile: file)
        XCTAssertFalse(result.shareCache)
    }
}
