import XCTest

@testable import KinhinKit

/// The token store never reaches the developer's real Keychain services from a
/// test process, even when a test forgets `serviceOverride`.
final class KeychainTestIsolationTests: XCTestCase {
    func testATestProcessWithoutAnOverrideUsesTheScratchService() {
        let saved = KeychainTokenStore.serviceOverride
        KeychainTokenStore.serviceOverride = nil
        defer { KeychainTokenStore.serviceOverride = saved }

        XCTAssertTrue(KeychainTokenStore.isTestProcess)
        XCTAssertEqual(KeychainTokenStore.service, KeychainTokenStore.testFallbackService)
        XCTAssertNotEqual(KeychainTokenStore.service, Paths.keychainService)
        XCTAssertFalse(KeychainTokenStore.usesRealKeychain, "no legacy migration or wipe from a test")
    }

    func testAnOverrideStillWins() {
        let saved = KeychainTokenStore.serviceOverride
        KeychainTokenStore.serviceOverride = "com.kinhin.runner.tests.\(UUID().uuidString)"
        defer { KeychainTokenStore.serviceOverride = saved }

        XCTAssertEqual(KeychainTokenStore.service, KeychainTokenStore.serviceOverride)
        XCTAssertFalse(KeychainTokenStore.usesRealKeychain)
    }
}
