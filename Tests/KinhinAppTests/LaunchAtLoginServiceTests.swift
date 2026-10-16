import ServiceManagement
import XCTest

@testable import kinhin_app

/// `LaunchAtLoginService.apply` against a scripted login item: never the real
/// SMAppService registration.
final class LaunchAtLoginServiceTests: XCTestCase {
    /// A scripted login item: a status, and the failures `register`/`unregister` throw.
    private final class ScriptedLoginItem: LoginItemRegistering {
        var status: SMAppService.Status
        var registerError: Error?
        /// The status after a register call (succeeding or not).
        var statusAfterRegister: SMAppService.Status = .enabled
        var unregisterError: Error?
        private(set) var calls: [String] = []

        init(status: SMAppService.Status) { self.status = status }

        func register() throws {
            calls.append("register")
            status = statusAfterRegister
            if let registerError { throw registerError }
        }

        func unregister() throws {
            calls.append("unregister")
            if let unregisterError { throw unregisterError }
            status = .notRegistered
        }
    }

    private let refused = NSError(
        domain: "SMAppServiceErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])

    func testEnablingRegistersOnce() throws {
        let item = ScriptedLoginItem(status: .notRegistered)
        try LaunchAtLoginService.apply(enabled: true, service: item, isBundled: true)
        XCTAssertEqual(item.calls, ["register"])
        try LaunchAtLoginService.apply(enabled: true, service: item, isBundled: true)
        XCTAssertEqual(item.calls, ["register"], "an enabled item is left alone")
    }

    func testDisablingUnregisters() throws {
        let item = ScriptedLoginItem(status: .enabled)
        try LaunchAtLoginService.apply(enabled: false, service: item, isBundled: true)
        XCTAssertEqual(item.calls, ["unregister"])
        XCTAssertEqual(item.status, .notRegistered)
    }

    func testARefusedRegistrationThrowsTheReason() {
        let item = ScriptedLoginItem(status: .notRegistered)
        item.registerError = refused
        item.statusAfterRegister = .notRegistered
        XCTAssertThrowsError(try LaunchAtLoginService.apply(enabled: true, service: item, isBundled: true)) {
            XCTAssertEqual($0 as? LaunchAtLoginError, .registerFailed("Operation not permitted"))
            XCTAssertEqual(($0 as? LaunchAtLoginError)?.leavesRegistered, false)
        }
    }

    func testAnItemAwaitingApprovalSaysWhereToApproveIt() {
        let item = ScriptedLoginItem(status: .notRegistered)
        item.statusAfterRegister = .requiresApproval
        XCTAssertThrowsError(try LaunchAtLoginService.apply(enabled: true, service: item, isBundled: true)) {
            XCTAssertEqual($0 as? LaunchAtLoginError, .requiresApproval)
            XCTAssertTrue($0.localizedDescription.contains("System Settings → General → Login Items"))
        }
    }

    func testARegisterErrorWhileAwaitingApprovalIsReportedAsApproval() {
        let item = ScriptedLoginItem(status: .requiresApproval)
        item.registerError = refused
        item.statusAfterRegister = .requiresApproval
        XCTAssertThrowsError(try LaunchAtLoginService.apply(enabled: true, service: item, isBundled: true)) {
            XCTAssertEqual($0 as? LaunchAtLoginError, .requiresApproval)
        }
    }

    func testARefusedRemovalLeavesTheItemRegistered() {
        let item = ScriptedLoginItem(status: .enabled)
        item.unregisterError = refused
        XCTAssertThrowsError(try LaunchAtLoginService.apply(enabled: false, service: item, isBundled: true)) {
            XCTAssertEqual($0 as? LaunchAtLoginError, .unregisterFailed("Operation not permitted"))
            XCTAssertEqual(($0 as? LaunchAtLoginError)?.leavesRegistered, true)
        }
    }

    func testAnUnbundledRunOnlyStoresThePreference() throws {
        let item = ScriptedLoginItem(status: .notRegistered)
        try LaunchAtLoginService.apply(enabled: true, service: item, isBundled: false)
        XCTAssertTrue(item.calls.isEmpty)
    }
}
