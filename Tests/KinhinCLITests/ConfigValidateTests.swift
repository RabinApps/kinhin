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
}
