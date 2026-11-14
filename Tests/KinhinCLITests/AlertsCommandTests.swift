import Synchronization
import XCTest

@testable import KinhinKit
@testable import kinhin

final class AlertsCommandTests: XCTestCase {
    func testSetTokenStoresTheStdinTokenUnderTheName() throws {
        let saved = Mutex<(String, String)?>(nil)
        try AlertsCommand.setToken(
            ["alerts", "set-token", "ops", "--token-stdin"], read: { "  abc123\n" },
            save: { token, name in saved.withLock { $0 = (token, name) } })
        let value = saved.withLock { $0 }
        XCTAssertEqual(value?.0, "abc123")
        XCTAssertEqual(value?.1, "ops")
    }

    func testTestRethrowsCancellationForTheCLIHandler() async {
        let config = Self.config
        do {
            try await AlertsCommand.test(config: config) { _, _ in throw CancellationError() }
            XCTFail("expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testTestPrintsTheSendersLine() async throws {
        let asked = Mutex<String??>(nil)
        try await AlertsCommand.test(config: Self.config) { _, name in
            asked.withLock { $0 = .some(name) }
            return ["test alert sent to ops (https://hooks.example.com)"]
        }
        XCTAssertEqual(asked.withLock { $0 }, .some(nil))
    }

    func testTestPassesTheWebhookNameThrough() async throws {
        let asked = Mutex<String?>(nil)
        try await AlertsCommand.test(config: Self.config, webhook: "ops") { _, name in
            asked.withLock { $0 = name }
            return []
        }
        XCTAssertEqual(asked.withLock { $0 }, "ops")
    }

    private static let config = KinhinConfig.AlertsConfig(
        enabled: true, webhooks: [.init(name: "ops", url: "https://hooks.example.com/x")])
}
