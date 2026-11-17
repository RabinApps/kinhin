import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// What the Runtimes page's runtime cards read from the models: each runtime's state (on, switched off, not set up),
/// the switch rules, the route rows, and the card that turns an unset-up runtime on.
@MainActor
final class RuntimesCardsTests: XCTestCase {
    private var configURL: URL!

    private let config = """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: ["self-hosted"]
        container:
          image: "kinhin-ci-linux"
          cpus: 2
          memory_gb: 4
        runtimes:
          default: tart
          routes:
            - pattern: "acme/api"
              runtime: appleContainer
            - pattern: "acme/web@Release Build"
              runtime: tart
        """

    override func setUp() async throws {
        try await super.setUp()
        configURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-cards-\(UUID().uuidString).yaml")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: configURL)
        try await super.tearDown()
    }

    private func loaded(_ yaml: String? = nil) async throws -> RuntimesModel {
        try (yaml ?? config).write(to: configURL, atomically: true, encoding: .utf8)
        let model = RuntimesModel()
        model.configURL = configURL
        model.reload()
        for _ in 0..<100 where !model.hasLoadedForTesting || model.isProbingHealth {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return model
    }

    func testPoolStatesDistinguishOnOffAndNotSetUp() async throws {
        let model = try await loaded()
        XCTAssertEqual(model.poolState(.tart), .on)
        XCTAssertEqual(model.poolState(.appleContainer), .on)
        XCTAssertEqual(model.poolState(.docker), .unconfigured, "no docker: section yet")
        XCTAssertEqual(model.poolState(.host), .on, "host has no switch and is always listed")
        XCTAssertTrue(model.isDefaultPool(.tart))
        XCTAssertFalse(model.isDefaultPool(.appleContainer))

        // The container is named by a route, so it cannot be turned off.
        XCTAssertFalse(model.canSwitchOff(.appleContainer))
        XCTAssertFalse(model.canSwitchOff(.tart), "the default pool stays on")
    }

    func testASwitchedOffPoolKeepsItsSettingsAndReadsAsOff() async throws {
        let yaml = """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: ["self-hosted"]
            container:
              image: "kinhin-ci-linux"
              cpus: 2
              memory_gb: 4
            runtimes:
              default: tart
            """
        let model = try await loaded(yaml)
        XCTAssertTrue(model.canSwitchOff(.appleContainer))
        model.setPoolEnabled(.appleContainer, false)
        for _ in 0..<100 where model.poolState(.appleContainer) != .off {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(model.poolState(.appleContainer), .off)
        XCTAssertTrue(model.canSwitchOff(.appleContainer), "a runtime that is already off has nothing to protect")
        XCTAssertTrue(try String(contentsOf: configURL, encoding: .utf8).contains("kinhin-ci-linux"))
    }

    func testRouteRowsCarryPatternRuntimeAndWorkflowFlag() async throws {
        let model = try await loaded()
        XCTAssertEqual(
            model.routeRows,
            [
                .init(pattern: "acme/api", runtime: .appleContainer, isWorkflow: false),
                .init(pattern: "acme/web@Release Build", runtime: .tart, isWorkflow: true),
            ])
        XCTAssertEqual(RuntimesModel.routeChipTitle(.host), "Host")
        XCTAssertEqual(RuntimesModel.routeChipTitle(.appleContainer), "Apple container")
        XCTAssertEqual(RuntimesModel.cardTitle(.tart), "macOS (Tart)")
    }

    func testTurningAnUnsetUpRuntimeOnCreatesItsSection() async throws {
        let model = try await loaded()
        let mac = MacToolsModel()
        mac.configURL = configURL
        model.setRuntimeOn(.docker, true, mac: mac)
        XCTAssertNotNil(try ConfigStore.snapshot(at: configURL)?.docker)
        for _ in 0..<100 where model.poolState(.docker) == .unconfigured {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotEqual(model.poolState(.docker), .unconfigured)
    }

    func testConfigMissingIsNotConfigUnreadable() async throws {
        let model = RuntimesModel()
        model.configURL = configURL
        XCTAssertTrue(model.configMissing)
        try "labels: [unterminated\n".write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(model.configMissing)
        model.reload()
        for _ in 0..<100 where !model.loadFailed {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(model.loadFailed)
        XCTAssertTrue(model.emptyMessage.contains("Fix it with Edit YAML"), model.emptyMessage)
    }
}
