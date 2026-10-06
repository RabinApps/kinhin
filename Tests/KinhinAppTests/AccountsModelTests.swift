import Synchronization
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
    private final class StoredNames: Sendable {
        private let names = Mutex<Set<String>>([])
        func contains(_ name: String) -> Bool { names.withLock { $0.contains(name) } }
        func insert(_ name: String) { _ = names.withLock { $0.insert(name) } }
        func set(_ new: Set<String>) { names.withLock { $0 = new } }
    }

    private let stored = StoredNames()
    private var saved: [(AccountConfig, String)] = []
    private var deleted: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-accts-\(UUID().uuidString).yaml")
        try "labels: [a]\n".write(to: url, atomically: true, encoding: .utf8)
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

    func testForgejoAccountAlsoNeedsAServerAddress() {
        let model = makeModel()
        add(model, name: "fj", forge: .forgejo, scope: "me")
        XCTAssertEqual(model.addStatus.style, .error)
        model.newInstance = "https://forge.lan"
        model.addAccount()
        XCTAssertEqual(model.addStatus.style, .ok)
        let account = try! AccountsConfigEditor.accounts(at: url).first { $0.name == "fj" }
        XCTAssertEqual(account?.forge, .forgejo)
        XCTAssertEqual(account?.instance, "https://forge.lan")
    }

    func testGitLabAccountAddsInTheGitLabComDefaultWithoutAServer() async {
        let model = makeModel()
        add(model, name: "gitlab", forge: .gitlab, scope: "acme/platform/api")
        await settle(model) { !model.rows.isEmpty }
        XCTAssertEqual(model.addStatus.style, .ok)
        let account = try! AccountsConfigEditor.accounts(at: url).first { $0.name == "gitlab" }
        XCTAssertEqual(account?.forge, .gitlab)
        XCTAssertNil(account?.instance, "blank → gitlab.com")
    }

    func testGitLabInstanceIsKeptWhenTyped() async {
        let model = makeModel()
        model.newInstance = "https://git.example.com/gitlab"
        add(model, name: "gl", forge: .gitlab, scope: "acme/api")
        await settle(model) { !model.rows.isEmpty }
        XCTAssertEqual(
            try! AccountsConfigEditor.accounts(at: url).first { $0.name == "gl" }?.instance,
            "https://git.example.com/gitlab")
    }

    func testForgeRequirementsCoverEveryForge() {
        let model = makeModel()
        let github = model.requirements(for: .github, scope: "acme/widgets", instance: nil)
        XCTAssertTrue(github.title.contains("GitHub"))
        let gitea = model.requirements(for: .gitea, scope: "me", instance: "https://git.lan")
        XCTAssertTrue(gitea.options.first?.url.contains("git.lan") == true)
        let gitlab = model.requirements(for: .gitlab, scope: "acme/api", instance: nil)
        XCTAssertTrue(
            gitlab.options.contains { $0.permissions.contains { $0.contains("create_runner") } },
            "the GitLab hint names the runner scopes")
        XCTAssertEqual(
            model.requirements(for: .forgejo, scope: "me", instance: nil).title,
            model.requirements(for: .gitea, scope: "me", instance: nil).title,
            "Forgejo shares the Gitea hint")
    }

    func testScopeAndInstancePlaceholdersPerForge() {
        let model = makeModel()
        XCTAssertEqual(model.scopePlaceholder(for: .gitlab), "group/subgroup or group/project")
        XCTAssertEqual(model.scopePlaceholder(for: .github), "owner/name, or an org")
        XCTAssertEqual(
            model.instancePlaceholder(for: .github),
            "e.g. https://github.example.com or https://acme.ghe.com",
            "GitHub hosts are enterprise GHES or GHEC data-residency instances")
        XCTAssertEqual(model.instancePlaceholder(for: .gitlab), "https://gitlab.com (optional)")
        XCTAssertFalse(model.instanceRequired(for: .gitlab))
        XCTAssertTrue(model.instanceRequired(for: .forgejo))
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

    /// The forge cards own each forge's conventional account (`github`,
    /// `gitea`, …); "More accounts" lists only the rest, so no account is
    /// shown twice, and a GitHub account named `work` is never claimed by
    /// the GitHub card (which writes by name and would add a duplicate).
    func testCardOwnedAccountsAreNotListedTwice() async throws {
        try AccountsConfigEditor.add(AccountConfig(name: "work", forge: .github, scope: "bigco"), to: url)
        try AccountsConfigEditor.add(AccountConfig(name: "github", forge: .github, scope: "acme"), to: url)
        let model = makeModel()
        model.reload()
        await settle(model) { !model.rows.isEmpty }
        XCTAssertEqual(model.rows.map(\.account.name), ["work"])
        XCTAssertEqual(ForgeConnectionModel.configuredAccount(forge: .github, at: url)?.name, "github")

        try AccountsConfigEditor.remove(name: "github", at: url)
        XCTAssertNil(
            ForgeConnectionModel.configuredAccount(forge: .github, at: url),
            "the card must not adopt an account it does not own")
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
