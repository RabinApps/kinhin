import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The Connect form's "More accounts" section: adding, verifying, storing
/// and removing extra accounts — all through injected seams, never the real
/// Keychain, network, or the developer's config.
@MainActor
final class AccountsModelTests: XCTestCase {
    private var url: URL!
    /// Read from the model's detached Keychain probe, so it is lock-guarded.
    private final class StoredNames: @unchecked Sendable {
        private let lock = NSLock()
        private var names: Set<String> = []
        func contains(_ name: String) -> Bool { lock.withLock { names.contains(name) } }
        func insert(_ name: String) { lock.withLock { _ = names.insert(name) } }
        func set(_ new: Set<String>) { lock.withLock { names = new } }
    }

    private let stored = StoredNames()
    private var saved: [(AccountConfig, String)] = []
    private var deleted: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-accts-\(UUID().uuidString).yaml")
        try "repo: acme/widgets\nlabels: [a]\n".write(to: url, atomically: true, encoding: .utf8)
        stored.set([])
        saved = []
        deleted = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: url)
        try await super.tearDown()
    }

    private func makeModel(verdict: StatusLine = StatusLine(text: "ok ✓", style: .ok)) -> AccountsModel {
        let model = AccountsModel()
        model.configURL = url
        let names = stored
        model.hasStoredToken = { _, name in names.contains(name) }
        model.saveToken = { [unowned self] account, token in
            self.saved.append((account, token))
            self.stored.insert(account.name)
        }
        model.deleteToken = { [unowned self] in self.deleted.append($0.name) }
        model.verifyToken = { _, _ in verdict }
        return model
    }

    private func settle(_ model: AccountsModel, until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func add(_ model: AccountsModel, name: String = "work", forge: ForgeID = .github, scope: String = "bigco") {
        model.newForge = forge
        model.newName = name
        model.newScope = scope
        model.addAccount()
    }

    func testAddWritesTheAccountAndClearsTheForm() async {
        let model = makeModel()
        var changes = 0
        model.onChanged = { changes += 1 }
        add(model)
        await settle(model) { !model.rows.isEmpty }
        XCTAssertEqual(model.rows.map(\.account.name), ["work"])
        XCTAssertEqual(model.newName, "")
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(try AccountsConfigEditor.accounts(at: url).map(\.name), ["work"])
    }

    func testInvalidAddShowsTheErrorAndWritesNothing() {
        let model = makeModel()
        add(model, name: "Bad Name")
        XCTAssertEqual(model.addStatus.style, .error)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue((try? AccountsConfigEditor.accounts(at: url))?.isEmpty == true)
    }

    func testGiteaAccountNeedsAServerAddress() {
        let model = makeModel()
        add(model, name: "home", forge: .gitea, scope: "me")
        XCTAssertEqual(model.addStatus.style, .error)
        model.newInstance = "https://git.lan"
        model.addAccount()
        XCTAssertEqual(model.addStatus.style, .ok)
    }

    func testReloadShowsTokenState() async throws {
        try AccountsConfigEditor.add(AccountConfig(name: "work", forge: .github, scope: "bigco"), to: url)
        try AccountsConfigEditor.add(AccountConfig(name: "side", forge: .github, scope: "me/x"), to: url)
        stored.set(["work"])
        let model = makeModel()
        model.reload()
        await settle(model) { model.rows.count == 2 }
        XCTAssertEqual(model.rows.map(\.tokenStored), [true, false])
    }

    func testConnectVerifiesThenStoresTheToken() async {
        let model = makeModel()
        add(model)
        await settle(model) { !model.rows.isEmpty }
        model.setTokenTextForTesting("work", "  ghp_abc \n")
        model.connect("work")
        await settle(model) { !self.saved.isEmpty }
        XCTAssertEqual(saved.first?.1, "ghp_abc", "the pasted token is trimmed")
        XCTAssertEqual(saved.first?.0.name, "work")
        XCTAssertEqual(model.tokenTexts["work"] ?? "", "", "the field is cleared after saving")
    }

    func testARejectedTokenIsNotStored() async {
        let model = makeModel(verdict: StatusLine(text: "PAT lacks permission", style: .error))
        add(model)
        await settle(model) { !model.rows.isEmpty }
        model.setTokenTextForTesting("work", "ghp_bad")
        model.connect("work")
        await settle(model) { model.rows.first?.checking == false && model.rows.first?.status.style == .error }
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(model.rows.first?.status.text, "PAT lacks permission")
    }

    func testRemoveDropsConfigEntryAndToken() async {
        let model = makeModel()
        add(model)
        await settle(model) { !model.rows.isEmpty }
        model.removeAccount("work")
        await settle(model) { model.rows.isEmpty }
        XCTAssertEqual(deleted, ["work"])
        XCTAssertTrue((try? AccountsConfigEditor.accounts(at: url))?.isEmpty == true)
    }

    func testConnectedAccountCountsTowardIsConnected() async {
        let connect = ConnectModel()
        connect.configURL = url
        connect.accounts.hasStoredToken = { _, _ in true }
        add(connect.accounts)
        await settle(connect.accounts) { !connect.accounts.rows.isEmpty }
        XCTAssertTrue(connect.isConnected)
    }
}
