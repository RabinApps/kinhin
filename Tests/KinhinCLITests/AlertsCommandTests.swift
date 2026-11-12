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

    func testTestPrintsTheSendersLine() async throws {
        let config = KinhinConfig.AlertsConfig(enabled: true, webhookURL: "https://hooks.example.com/x")
        let asked = Mutex(false)
        try await AlertsCommand.test(config: config) { _ in
            asked.withLock { $0 = true }
            return "test alert sent to https://hooks.example.com"
        }
        XCTAssertTrue(asked.withLock { $0 })
    }
}
