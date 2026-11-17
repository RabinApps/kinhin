import XCTest

@testable import KinhinKit

/// The LaunchAgent carries `TART_HOME` from `tart_home:`, and a reinstall keeps the variables the plist had.
final class DaemonAgentEnvironmentTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func parsed(_ text: String) throws -> [String: Any] {
        let root = try PropertyListSerialization.propertyList(from: Data(text.utf8), options: [], format: nil)
        return try XCTUnwrap(root as? [String: Any])
    }

    func testTartHomeBecomesTheAgentEnvironment() {
        XCTAssertEqual(
            Daemon.agentEnvironment(for: .init(tartHome: "/Volumes/Storage/tart")),
            ["TART_HOME": "/Volumes/Storage/tart"])
        XCTAssertEqual(Daemon.agentEnvironment(for: .init(containerAppRoot: "/Volumes/Storage/container")), [:])
    }

    func testThePlistCarriesEnvironmentVariablesAndStaysValid() throws {
        let text = Daemon.agentPlist(
            binaryPath: "/usr/local/bin/kinhin", logs: dir,
            environment: ["TART_HOME": "/Volumes/A & B/tart", "LANG": "en_US.UTF-8"])
        let root = try parsed(text)
        XCTAssertEqual(
            root["EnvironmentVariables"] as? [String: String],
            ["TART_HOME": "/Volumes/A & B/tart", "LANG": "en_US.UTF-8"])
        XCTAssertEqual(root["ProgramArguments"] as? [String], ["/usr/local/bin/kinhin", "daemon"])
        XCTAssertEqual(root["KeepAlive"] as? Bool, true)
    }

    func testAPlistWithoutEnvironmentHasNoEnvironmentKey() throws {
        let root = try parsed(Daemon.agentPlist(binaryPath: "/usr/local/bin/kinhin", logs: dir, environment: [:]))
        XCTAssertNil(root["EnvironmentVariables"])
        XCTAssertEqual(root["Label"] as? String, Daemon.label)
    }

    func testTheExistingPlistsVariablesAreReadBack() throws {
        let url = dir.appendingPathComponent("agent.plist")
        try Daemon.agentPlist(binaryPath: "/bin/kinhin", logs: dir, environment: ["TART_HOME": "/Volumes/S/tart"])
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(Daemon.existingAgentEnvironment(at: url), ["TART_HOME": "/Volumes/S/tart"])
        XCTAssertEqual(Daemon.existingAgentEnvironment(at: dir.appendingPathComponent("missing.plist")), [:])
        let broken = dir.appendingPathComponent("broken.plist")
        try "not a plist".write(to: broken, atomically: true, encoding: .utf8)
        XCTAssertEqual(Daemon.existingAgentEnvironment(at: broken), [:])
    }

    func testARemovedTartHomeLeavesTheAgentButOtherVariablesStay() {
        let existing = ["TART_HOME": "/Volumes/Old/tart", "LANG": "en_US.UTF-8"]
        XCTAssertEqual(
            Daemon.mergedAgentEnvironment(
                existing: existing, environment: [:], managed: Daemon.configManagedAgentVariables),
            ["LANG": "en_US.UTF-8"])
        XCTAssertEqual(
            Daemon.mergedAgentEnvironment(
                existing: existing, environment: ["TART_HOME": "/Volumes/New/tart"],
                managed: Daemon.configManagedAgentVariables),
            ["TART_HOME": "/Volumes/New/tart", "LANG": "en_US.UTF-8"])
    }

    func testAConfigThatDidNotLoadKeepsEveryVariable() {
        let existing = ["TART_HOME": "/Volumes/Old/tart", "LANG": "en_US.UTF-8"]
        XCTAssertEqual(Daemon.mergedAgentEnvironment(existing: existing, environment: [:], managed: []), existing)
    }
}
