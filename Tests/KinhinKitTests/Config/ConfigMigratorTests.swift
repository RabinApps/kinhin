import XCTest

@testable import KinhinKit

final class ConfigMigratorTests: XCTestCase {
    private func parsed(_ migration: ConfigMigration, file: StaticString = #filePath, line: UInt = #line) throws
        -> KinhinConfig
    {
        XCTAssertEqual(migration.warnings.filter { $0.contains("does not validate") }, [], file: file, line: line)
        return try ConfigLoader.parse(migration.yaml)
    }

    // MARK: - No-ops

    func testCurrentSchemaIsLeftAlone() throws {
        let yaml =
            "# my config\naccounts:\n  - name: github\n    forge: github\n    scope: acme/widgets\nmax_runners: 3\n"
        let migration = try ConfigMigrator.migrate(yaml)
        XCTAssertTrue(migration.isNoop)
        XCTAssertEqual(migration.yaml, yaml)
        XCTAssertEqual(migration.warnings, [])
    }

    func testMigrationIsIdempotent() throws {
        let first = try ConfigMigrator.migrate("repo: acme/widgets\nlabels: [a]\n")
        XCTAssertFalse(first.isNoop)
        let second = try ConfigMigrator.migrate(first.yaml)
        XCTAssertTrue(second.isNoop)
        XCTAssertEqual(second.yaml, first.yaml)
    }

    func testNonYAMLThrows() {
        XCTAssertThrowsError(try ConfigMigrator.migrate("labels: [unterminated\n")) { error in
            XCTAssertTrue(error is ConfigError)
        }
    }

    // MARK: - repo:

    func testRepoBecomesTheGitHubAccount() throws {
        let yaml = """
            # fleet for the widgets repo
            repo: acme/widgets
            labels: ["self-hosted", "macos"]
            max_runners: 3   # keep small
            """
        let migration = try ConfigMigrator.migrate(yaml)
        let cfg = try parsed(migration)
        XCTAssertEqual(cfg.accounts, [AccountConfig(name: "github", forge: .github, scope: "acme/widgets")])
        XCTAssertEqual(cfg.maxRunners, 3)
        XCTAssertTrue(migration.yaml.contains("# fleet for the widgets repo"), "comments elsewhere survive")
        XCTAssertTrue(migration.yaml.contains("max_runners: 3   # keep small"))
        XCTAssertFalse(migration.yaml.contains("repo: acme"), migration.yaml)
        XCTAssertEqual(migration.changes.count, 1)
    }

    func testOrgScopeKeepsItsShape() throws {
        let cfg = try parsed(try ConfigMigrator.migrate("repo: acme\n"))
        XCTAssertEqual(cfg.accounts.first?.scope, "acme")
    }

    func testEmptyRepoIsJustRemoved() throws {
        let migration = try ConfigMigrator.migrate("repo: \"\"\nlabels: [a]\n")
        XCTAssertFalse(migration.isNoop)
        XCTAssertFalse(migration.yaml.contains("repo"), migration.yaml)
        XCTAssertTrue(try parsed(migration).accounts.isEmpty)
    }

    // MARK: - gitea: / forgejo:

    func testGiteaAndForgejoBecomeAccounts() throws {
        let yaml = """
            repo: acme/widgets
            gitea:
              instance: https://gitea.example.com
              scope: acme/widgets
              labels: ["macos:host"]
            forgejo:
              instance: https://forge.example.com
              scope: acme
            min_runners: 1
            """
        let migration = try ConfigMigrator.migrate(yaml)
        let cfg = try parsed(migration)
        XCTAssertEqual(cfg.accounts.map(\.name), ["github", "gitea", "forgejo"])
        XCTAssertEqual(cfg.accounts[1].forge, .gitea)
        XCTAssertEqual(cfg.accounts[1].instance, "https://gitea.example.com")
        XCTAssertEqual(cfg.accounts[1].labels, ["macos:host"])
        XCTAssertEqual(cfg.accounts[2].forge, .forgejo)
        XCTAssertEqual(cfg.minRunners, 1)
        XCTAssertEqual(migration.yaml.components(separatedBy: "accounts:").count - 1, 1, "one accounts: block")
    }

    func testGiteaWithoutInstanceWarns() throws {
        let migration = try ConfigMigrator.migrate("gitea:\n  scope: acme/widgets\n")
        XCTAssertTrue(migration.warnings.contains { $0.contains("instance") }, "\(migration.warnings)")
    }

    func testGiteaWithoutScopeIsLeftInPlaceWithAWarning() throws {
        let migration = try ConfigMigrator.migrate("gitea:\n  instance: https://g.example.com\nlabels: [a]\n")
        XCTAssertTrue(migration.isNoop)
        XCTAssertTrue(migration.warnings.contains { $0.contains("gitea:") })
    }

    // MARK: - existing accounts:

    func testLegacyKeysAreAppendedToAnExistingAccountsBlock() throws {
        let yaml = """
            repo: acme/widgets
            accounts:
              - name: work
                forge: gitlab
                scope: group/project
            labels: [a]
            """
        let migration = try ConfigMigrator.migrate(yaml)
        let cfg = try parsed(migration)
        XCTAssertEqual(cfg.accounts.map(\.name), ["work", "github"])
        XCTAssertTrue(migration.yaml.contains("labels: [a]"))
    }

    func testFlowStyleAccountsCannotBeExtendedAndKeepTheLegacyKey() throws {
        let yaml = "repo: acme/widgets\naccounts: [{name: work, forge: gitlab, scope: group/project}]\n"
        let migration = try ConfigMigrator.migrate(yaml)
        XCTAssertTrue(migration.isNoop)
        XCTAssertEqual(migration.yaml, yaml)
        XCTAssertTrue(migration.warnings.contains { $0.contains("accounts:") })
    }

    // MARK: - toolchains:

    func testGlobalToolchainsBecomeAProjectForTheMigratedOwner() throws {
        let yaml = """
            repo: acme/widgets
            toolchains:
              specs: ["go@1.23.4", "node@22"]
              brew: [wget]
              stacks: [flutter]
              share_cache: true
              cache:
                auto_prune: true
                max_age_days: 30
                max_gb: 20
            labels: [a]
            """
        let migration = try ConfigMigrator.migrate(yaml)
        let cfg = try parsed(migration)
        XCTAssertEqual(cfg.projects.count, 1)
        let project = try XCTUnwrap(cfg.projects.first)
        XCTAssertEqual(project.pattern, "acme/*")
        XCTAssertEqual(project.toolchains?.specs, ["go@1.23.4", "node@22"])
        XCTAssertEqual(project.toolchains?.brew, ["wget"])
        XCTAssertEqual(project.toolchains?.stacks, ["flutter"])
        XCTAssertEqual(project.shareCache, true)
        XCTAssertEqual(
            cfg.toolchainCache, KinhinConfig.ToolchainCacheConfig(autoPrune: true, maxAgeDays: 30, maxGB: 20))
        XCTAssertTrue(migration.warnings.contains { $0.contains("acme/*") })
    }

    func testToolchainsWithoutAnyForgeUseAPlaceholderPattern() throws {
        let migration = try ConfigMigrator.migrate("toolchains:\n  specs: [\"go@1.23.4\"]\n")
        XCTAssertTrue(migration.yaml.contains("OWNER/*"), migration.yaml)
        XCTAssertTrue(migration.warnings.contains { $0.contains("OWNER/*") })
    }

    func testToolchainsAppendToExistingProjects() throws {
        let yaml = """
            repo: acme/widgets
            toolchains:
              specs: ["go@1.23.4"]
            projects:
              - pattern: other/repo
                repo_file: true
            """
        let cfg = try parsed(try ConfigMigrator.migrate(yaml))
        XCTAssertEqual(cfg.projects.map(\.pattern), ["other/repo", "acme/*"])
    }

    func testMultipleOwnersGetOneProjectEach() throws {
        let yaml = """
            repo: acme/widgets
            gitea:
              instance: https://g.example.com
              scope: other/thing
            toolchains:
              specs: ["go@1.23.4"]
            """
        let cfg = try parsed(try ConfigMigrator.migrate(yaml))
        XCTAssertEqual(cfg.projects.map(\.pattern), ["acme/*", "other/*"])
    }

    // MARK: - Messages and files

    func testRemovedKeyErrorsPointAtTheMigration() {
        for legacy in [
            "repo: acme/widgets", "gitea:\n  scope: a/b\n  instance: https://g.example.com",
            "toolchains:\n  specs: [x]",
        ] {
            XCTAssertThrowsError(try ConfigLoader.parse(legacy)) { error in
                XCTAssertTrue(error.localizedDescription.contains(ConfigMigrator.hint), error.localizedDescription)
            }
        }
    }

    func testMigratedLegacyConfigLoadsWhereTheOriginalDoesNot() throws {
        let legacy = "repo: acme/widgets\nlabels: [a]\n"
        XCTAssertThrowsError(try ConfigLoader.parse(legacy))
        XCTAssertNoThrow(try ConfigLoader.parse(try ConfigMigrator.migrate(legacy).yaml))
    }

    func testMigratingAFileDoesNotWriteIt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).yaml")
        let legacy = "repo: acme/widgets\n"
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let migration = try ConfigMigrator.migrate(fileAt: url)
        XCTAssertFalse(migration.isNoop)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), legacy)
    }

    func testMigratingAMissingFileThrowsNotFound() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).yaml")
        XCTAssertThrowsError(try ConfigMigrator.migrate(fileAt: url)) { error in
            XCTAssertEqual(error as? ConfigError, .notFound(url.path))
        }
    }
}
