import AppKit
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// A config.yaml that stops parsing must be said on each form's status line,
/// never rendered as an empty config (CLAUDE.md: load config through
/// `ConfigStore` so a parse error is shown).
@MainActor
final class BrokenConfigFormsTests: XCTestCase {
    private var configURL: URL!

    private static let valid = """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: [self-hosted]
        container:
          image: "kinhin-ci-linux"
        docker:
          image: "kinhin-ci-linux"
        """

    override func setUp() async throws {
        try await super.setUp()
        configURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-broken-\(UUID().uuidString).yaml")
        try Self.valid.write(to: configURL, atomically: true, encoding: .utf8)
        AlertKit.runModal = { _ in .alertFirstButtonReturn }
    }

    override func tearDown() async throws {
        AlertKit.runModal = { $0.runModal() }
        try? FileManager.default.removeItem(at: configURL)
        try await super.tearDown()
    }

    private func breakConfig() throws {
        try "- just\n- a list\n".write(to: configURL, atomically: true, encoding: .utf8)
    }

    func testToolchainsSaysSoWhenTheConfigBreaks() throws {
        let model = ToolchainsModel()
        model.configURL = configURL
        model.reload()
        try breakConfig()

        model.reload()

        XCTAssertTrue(model.statusTextForTesting.contains("config.yaml has a problem"), model.statusTextForTesting)
        XCTAssertTrue(model.rows.isEmpty, "no rows are rendered as if nothing were configured")
    }

    func testMacToolsSaysSoWhenTheConfigBreaksUnderAnEdit() throws {
        let model = MacToolsModel()
        model.configURL = configURL
        model.reload()
        try breakConfig()

        model.saveDockerPlatform(.amd64)

        XCTAssertTrue(model.busyLine.text.contains("config.yaml can't be read"), model.busyLine.text)
        XCTAssertEqual(model.busyLine.style, .error)
        XCTAssertEqual(model.dockerPlatform, .arm64, "defaults aren't passed off as saved values")
    }

    func testCapacitySaysSoWhenTheConfigBreaksUnderApply() throws {
        let model = CapacityModel()
        model.configURL = configURL
        model.reload()
        model.stage("max-runners", .maxRunners(6))
        try breakConfig()

        model.applyPending()

        XCTAssertTrue(model.status.text.contains("config.yaml can't be read"), model.status.text)
        XCTAssertEqual(model.status.style, .error)
    }
}
