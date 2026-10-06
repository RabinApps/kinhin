import XCTest

@testable import KinhinKit
@testable import kinhin

final class ConfigValidateTests: XCTestCase {
    private var scratch: URL!
    private var configURL: URL { scratch.appendingPathComponent("config.yaml") }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-validate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testValidConfigPrintsASummaryAndWritesNothing() throws {
        try """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: [self-hosted, macos]
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: configURL)
        let summary = try ConfigCommands.validate(configURL: configURL)
        XCTAssertTrue(summary.contains("config OK"), summary)
        XCTAssertTrue(summary.contains("github (github, acme/widgets)"), summary)
        XCTAssertEqual(try Data(contentsOf: configURL), before)
    }

    func testInvalidConfigThrowsTheLoadersError() throws {
        try "poll_interval: 1\n".write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ConfigCommands.validate(configURL: configURL)) { error in
            XCTAssertTrue(error is ConfigError, "\(error)")
        }
    }

    func testMissingFileAndStarterTemplateAreErrors() throws {
        XCTAssertThrowsError(try ConfigCommands.validate(configURL: configURL))
        try ConfigCommands.configInit([], configURL: configURL)
        XCTAssertThrowsError(try ConfigCommands.validate(configURL: configURL)) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("no accounts"), "\(error)")
        }
    }

    // MARK: - the --json document

    func testValidationDocumentReportsTheParsedFacts() throws {
        try """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: [self-hosted, macos]
        runtimes:
          routes:
            - pattern: acme/widgets
              runtime: tart
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let document = ConfigCommands.validationDocument(configURL: configURL)
        XCTAssertEqual(
            document,
            .init(
                valid: true, path: configURL.path, error: nil,
                accounts: [.init(name: "github", forge: "github", scope: "acme/widgets")],
                labels: ["self-hosted", "macos"], runtimeRoutes: 1)
        )
    }

    func testValidationDocumentReportsFailuresInsteadOfThrowing() throws {
        try "poll_interval: 1\n".write(to: configURL, atomically: true, encoding: .utf8)
        let document = ConfigCommands.validationDocument(configURL: configURL)
        XCTAssertFalse(document.valid)
        XCTAssertFalse(document.error?.isEmpty ?? true, "the failure must say why")
        XCTAssertTrue(document.accounts.isEmpty)
        // The prose path classifies the same failure as a config error (exit 3).
        XCTAssertThrowsError(try ConfigCommands.validate(configURL: configURL)) { error in
            XCTAssertTrue(error is ConfigError, "\(error)")
        }
    }

    func testValidationDocumentEncodesTheMachineContract() throws {
        try "poll_interval: 1\n".write(to: configURL, atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let object = try JSONSerialization.jsonObject(
            with: try encoder.encode(ConfigCommands.validationDocument(configURL: configURL)))
        let document = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(document["valid"] as? Bool, false)
        XCTAssertEqual(document["path"] as? String, configURL.path)
        XCTAssertFalse((document["error"] as? String ?? "").isEmpty)
    }
}
