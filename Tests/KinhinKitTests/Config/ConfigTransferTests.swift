import XCTest

@testable import KinhinKit

/// Moving a config between Macs: the export header, validation before anything
/// is written, the backup, and what the new Mac still needs.
final class ConfigTransferTests: XCTestCase {
    private var scratch: URL!
    private var configURL: URL { scratch.appendingPathComponent("Kinhin/config.yaml") }

    private let yaml = """
        accounts:
          - name: github
            forge: github
            scope: acme
          - name: home
            forge: gitea
            scope: me/app
            instance: "https://git.example.com"
        labels: [self-hosted]
        max_runners: 4

        """

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func writeConfig(_ body: String) throws {
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func plan(_ incoming: String, stored: Set<String> = []) throws -> ConfigTransfer.ImportPlan {
        try ConfigTransfer.plan(
            incoming: incoming, configURL: configURL, tokenStored: { _, name in stored.contains(name) },
            fileExists: { _ in false })
    }

    // MARK: - Export

    func testExportIsTheConfigUnderAHeaderThatNamesTheMacAndNoTokens() throws {
        try writeConfig(yaml)
        let text = try ConfigTransfer.export(
            configURL: configURL, host: "mini.local", date: Date(timeIntervalSince1970: 0))
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "# kinhin export: from mini.local at 1970-01-01T00:00:00Z.")
        XCTAssertTrue(lines[1].contains("tokens are not included"))
        XCTAssertTrue(text.hasSuffix(yaml), "the config itself is unchanged")
        XCTAssertNoThrow(try ConfigLoader.parse(text), "an export is itself a valid config")
    }

    func testReExportingDoesNotStackHeaders() throws {
        try writeConfig(yaml)
        try writeConfig(try ConfigTransfer.export(configURL: configURL, host: "a"))
        let again = try ConfigTransfer.export(configURL: configURL, host: "b")
        XCTAssertEqual(again.components(separatedBy: "\n").filter { $0.hasPrefix("# kinhin export:") }.count, 3)
        XCTAssertTrue(again.contains("from b at"))
        XCTAssertFalse(again.contains("from a at"))
    }

    func testAnInvalidConfigIsNotExported() throws {
        try writeConfig("labels: [a]\nbogus_key: 1\n")
        XCTAssertThrowsError(try ConfigTransfer.export(configURL: configURL, host: "a"))
    }

    // MARK: - Import

    func testImportIntoAFreshMacWritesAPrivateConfigWithoutTheHeader() throws {
        try writeConfig(yaml)
        let exported = try ConfigTransfer.export(configURL: configURL, host: "a")
        try FileManager.default.removeItem(at: configURL.deletingLastPathComponent())

        let plan = try plan(exported)
        XCTAssertFalse(plan.replacesExisting)
        XCTAssertFalse(plan.unchanged)
        try ConfigTransfer.apply(plan)

        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), yaml)
        let mode = try FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.backupURL.path), "nothing to back up")
    }

    func testReplacingKeepsTheCurrentConfigAsABackup() throws {
        try writeConfig(yaml)
        let incoming = yaml.replacingOccurrences(of: "max_runners: 4", with: "max_runners: 8")
        let plan = try plan(incoming)
        XCTAssertTrue(plan.replacesExisting)
        try ConfigTransfer.apply(plan)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), incoming)
        XCTAssertEqual(try String(contentsOf: plan.backupURL, encoding: .utf8), yaml)
    }

    func testTheSameConfigIsUnchanged() throws {
        try writeConfig(yaml)
        let exported = try ConfigTransfer.export(configURL: configURL, host: "a")
        XCTAssertTrue(try plan(exported).unchanged, "the header alone is no change")
    }

    func testAnInvalidImportThrowsBeforeAnythingIsWritten() throws {
        try writeConfig(yaml)
        XCTAssertThrowsError(try plan("labels: [a]\nbogus_key: 1\n"))
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), yaml)
    }

    func testThePlanListsWhichAccountsStillNeedATokenHere() throws {
        let plan = try plan(yaml, stored: ["github"])
        XCTAssertEqual(
            plan.accounts,
            [
                .init(name: "github", forge: .github, tokenStored: true),
                .init(name: "home", forge: .gitea, tokenStored: false),
            ])
    }

    func testATartPathMissingOnThisMacIsAWarning() throws {
        let plan = try plan(yaml + "tart_path: /opt/elsewhere/tart\n")
        XCTAssertEqual(plan.warnings.count, 1)
        XCTAssertTrue(plan.warnings[0].contains("/opt/elsewhere/tart"))
    }
}
