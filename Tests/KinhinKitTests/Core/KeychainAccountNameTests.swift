import XCTest

@testable import KinhinKit

final class KeychainAccountNameTests: XCTestCase {
    func testLegacyNamesKeepOriginalKeychainItems() {
        XCTAssertEqual(KeychainTokenStore.account(for: .github, name: "github"), "github-pat")
        XCTAssertEqual(KeychainTokenStore.account(for: .gitea, name: "gitea"), "gitea-pat")
    }

    func testNamedAccountsGetTheirOwnItem() {
        XCTAssertEqual(KeychainTokenStore.account(for: .github, name: "work"), "github-pat:work")
        XCTAssertEqual(KeychainTokenStore.account(for: .gitea, name: "home"), "gitea-pat:home")
    }

    func testSameNameOnDifferentForgesDoesNotCollide() {
        XCTAssertNotEqual(
            KeychainTokenStore.account(for: .github, name: "work"),
            KeychainTokenStore.account(for: .gitea, name: "work"))
    }
}
