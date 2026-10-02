import XCTest

@testable import KinhinKit

final class ProjectsConfigTests: XCTestCase {
    private func parse(_ projects: String) throws -> KinhinConfig {
        try ConfigLoader.parse(
            """
            accounts:
              - {name: github, forge: github, scope: acme/api}
            projects:
            \(projects)
            """)
    }

    func testParsesEntries() throws {
        let cfg = try parse(
            """
              - pattern: acme/*
                repo_file: true
              - pattern: acme/api
                share_cache: true
                toolchains: {specs: [go@1.22.5]}
            """)
        XCTAssertEqual(cfg.projects.count, 2)
        XCTAssertTrue(cfg.projects[0].repoFile)
        XCTAssertFalse(cfg.projects[1].repoFile)
        XCTAssertEqual(cfg.projects[1].toolchains?.specs, ["go@1.22.5"])
        XCTAssertEqual(cfg.projects[1].shareCache, true)
    }

    func testAbsentSectionIsEmpty() throws {
        XCTAssertTrue(try ConfigLoader.parse("accounts:\n  - {name: github, forge: github, scope: a/b}\n").projects.isEmpty)
    }

    func testBadPatternsAreRejected() {
        for pattern in ["acme", "acme/api@Workflow", "*/api", "acme/a*b", "/api"] {
            XCTAssertThrowsError(try parse("  - pattern: \(pattern)\n"), pattern)
        }
    }

    func testDuplicatePatternsAreRejectedCaseInsensitively() {
        XCTAssertThrowsError(try parse("  - pattern: acme/api\n  - pattern: Acme/API\n"))
    }

    func testProjectToolchainsRunThroughGlobalValidation() {
        XCTAssertThrowsError(try parse("  - pattern: acme/api\n    toolchains: {stacks: [nonsense]}\n"))
    }

    func testMatching() {
        let exact = KinhinConfig.ProjectConfig(pattern: "acme/api")
        let owner = KinhinConfig.ProjectConfig(pattern: "acme/*")
        XCTAssertTrue(exact.matches("Acme/API"))
        XCTAssertFalse(exact.matches("acme/web"))
        XCTAssertTrue(owner.matches("acme/web"))
        XCTAssertFalse(owner.matches("other/web"))
    }
}
