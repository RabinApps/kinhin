import XCTest

@testable import KinhinKit
@testable import kinhin

/// `kinhin config import`: --yes gates replacing a config, stdin works, and
/// the report names what this Mac still needs.
final class ConfigTransferCommandTests: XCTestCase {
    private var scratch: URL!
    private var configURL: URL { scratch.appendingPathComponent("config.yaml") }
    private let yaml = "accounts:\n  - name: work\n    forge: gitlab\n    scope: grp/app\nlabels: [self-hosted]\n"

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-cli-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func importConfig(_ args: [String], stdin: String = "") throws {
        try ConfigCommands.importConfig(
            args, configURL: configURL, readStdin: { Data(stdin.utf8) }, daemonRunning: { false })
    }

    private var current: String? { try? String(contentsOf: configURL, encoding: .utf8) }

    func testAnExistingConfigIsOnlyReplacedWithYes() throws {
        try "labels: [old]\n".write(to: configURL, atomically: true, encoding: .utf8)
        try importConfig(["-"], stdin: yaml)
        XCTAssertEqual(current, "labels: [old]\n", "without --yes nothing is touched")

        try importConfig(["-", "--yes"], stdin: yaml)
        XCTAssertEqual(current, yaml)
    }

    func testAFreshMacNeedsNoYes() throws {
        let file = scratch.appendingPathComponent("from-other-mac.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        try importConfig([file.path])
        XCTAssertEqual(current, yaml)
    }

    func testMissingFileArgumentIsAUsageError() {
        XCTAssertThrowsError(try importConfig(["--yes"])) { error in
            XCTAssertEqual(CLIExit(error), .usage)
        }
    }

    func testTheReportListsTokensToStoreAndNextSteps() throws {
        let plan = try ConfigTransfer.plan(
            incoming: yaml, configURL: configURL, tokenStored: { _, _ in false }, fileExists: { _ in true })
        let lines = ConfigCommands.importReport(plan, applied: true, daemonRunning: true)
        XCTAssertEqual(lines.first, "imported into \(configURL.path)")
        XCTAssertTrue(lines.contains("  kinhin auth set --account work   (gitlab)"), lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.contains("kinhin setup status") })
        XCTAssertTrue(lines.last?.contains("restart") ?? false)
    }

    func testADryRunSaysHowToApply() throws {
        try "labels: [old]\n".write(to: configURL, atomically: true, encoding: .utf8)
        let plan = try ConfigTransfer.plan(
            incoming: yaml, configURL: configURL, tokenStored: { _, _ in true }, fileExists: { _ in true })
        let lines = ConfigCommands.importReport(plan, applied: false, daemonRunning: false)
        XCTAssertTrue(lines[1].contains("--yes"))
        XCTAssertFalse(lines.contains { $0.contains("auth set") }, "every token is already here")
    }
}
