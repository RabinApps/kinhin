import XCTest

@testable import KinhinKit

/// Forgejo tokens used to live in Gitea's Keychain items. Loading one moves
/// it into Forgejo's own item without losing it or the `gitea:` token.
final class ForgejoTokenMigrationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KeychainTokenStore.serviceOverride = "com.kinhin.runner.tests.\(UUID().uuidString)"
    }

    override func tearDown() {
        for name in ["gitea", "work"] { KeychainTokenStore.delete(forge: .gitea, name: name) }
        for name in ["forgejo", "work"] { KeychainTokenStore.delete(forge: .forgejo, name: name) }
        KeychainTokenStore.serviceOverride = nil
        super.tearDown()
    }

    func testLegacyForgejoTokenIsCopiedAndGiteaItemKept() throws {
        // Before the fix, `forgejo:` and `gitea:` both wrote "gitea-pat".
        try KeychainTokenStore.save("shared", forge: .gitea)

        XCTAssertEqual(try KeychainTokenStore.load(forge: .forgejo), "shared")
        XCTAssertEqual(try KeychainTokenStore.load(forge: .gitea), "shared", "the gitea: token is untouched")

        // Forgejo now reads its own item: replacing it no longer clobbers Gitea.
        try KeychainTokenStore.save("fj-new", forge: .forgejo)
        XCTAssertEqual(try KeychainTokenStore.load(forge: .forgejo), "fj-new")
        XCTAssertEqual(try KeychainTokenStore.load(forge: .gitea), "shared")
    }

    func testNamedForgejoAccountMovesOutOfGiteaItem() throws {
        try KeychainTokenStore.save("fj", forge: .gitea, name: "work")

        XCTAssertEqual(try KeychainTokenStore.load(forge: .forgejo, name: "work"), "fj")
        XCTAssertNil(try KeychainTokenStore.load(forge: .gitea, name: "work"), "the old item is removed")
        XCTAssertEqual(try KeychainTokenStore.load(forge: .forgejo, name: "work"), "fj")
    }

    func testNoTokenAnywhereStaysNil() throws {
        XCTAssertNil(try KeychainTokenStore.load(forge: .forgejo))
    }
}
