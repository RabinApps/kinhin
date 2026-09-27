import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The Connect form's chip selector and uniform per-forge cards, backed by
/// `ForgeConnectionModel`. All through injected seams — never the real
/// Keychain, network, or the developer's config.
@MainActor
final class ConnectModelTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-connect-\\(UUID().uuidString).yaml")
        try? "repo: \"your-org/your-repo\"\nlabels: [a]\n".write(to: url, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    /// - Parameter reload: pass `false` in tests that select a forge by hand
    ///   and then suspend: the async render would otherwise run mid-test and
    ///   reset the selection to what the (empty) config says.
    private func makeModel(stored: Set<ForgeID> = [], reload: Bool = true) -> ConnectModel {
        let model = ConnectModel()
        model.configURL = url
        model.hasStoredToken = { stored.contains($0) }
        model.loadToken = { _ in nil }
        model.checkPermission = { _, _ in nil }
        if reload { model.reload() }
        return model
    }

    private func settle(_ model: ConnectModel, until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    // MARK: Selector

    func testFreshInstallStartsWithNothingSelectedAndNoCards() {
        let model = makeModel()
        for forge in ConnectModel.allForges {
            XCTAssertFalse(model.isSelected(forge), "\\(forge)")
            XCTAssertNil(model.card(for: forge))
        }
        XCTAssertFalse(model.isConnected)
    }

    func testExistingInstallPreselectsConfiguredForges() async throws {
        try AccountsConfigEditor.add(
            AccountConfig(name: "gitlab", forge: .gitlab, scope: "acme/platform/api"), to: url)
        try GeneralConfigEditor.apply(.gitea(.init(instance: "https://git.example.com", scope: "team/repo")), to: url)
        let model = makeModel()
        await settle(model) { model.isSelected(.gitlab) && model.isSelected(.gitea) }
        XCTAssertFalse(model.isSelected(.github), "the template repo reads as nothing configured")
        XCTAssertTrue(model.isSelected(.gitlab))
        XCTAssertTrue(model.isSelected(.gitea))
        XCTAssertFalse(model.isSelected(.forgejo))
    }

    func testSelectingAForgeCreatesItsCard() {
        let model = makeModel()
        model.setSelected(true, for: .gitlab)
        XCTAssertNotNil(model.card(for: .gitlab))
        XCTAssertEqual(model.card(for: .gitlab)?.forge, .gitlab)
        XCTAssertNil(model.card(for: .gitea))
    }

    func testCardOrderFollowsTheSelectorNotSelectionOrder() {
        let model = makeModel()
        model.setSelected(true, for: .forgejo)
        model.setSelected(true, for: .github)
        let visible = ConnectModel.allForges.filter { model.card(for: $0) != nil }
        XCTAssertEqual(visible, [.github, .forgejo])
    }

    // MARK: Deselect

    func testDeselectingAConfiguredForgeAsksForConfirmation() async throws {
        try GeneralConfigEditor.apply(.gitea(.init(instance: "https://git.example.com", scope: "team/repo")), to: url)
        let model = makeModel()
        await settle(model) { model.isSelected(.gitea) }
        model.setSelected(false, for: .gitea)
        XCTAssertEqual(model.pendingDeselect, .gitea, "saved config: confirm before removing")
        XCTAssertTrue(model.isSelected(.gitea), "the card stays until confirmed")

        model.confirmDeselect()
        XCTAssertNil(model.pendingDeselect)
        XCTAssertFalse(model.isSelected(.gitea))
        XCTAssertNil(model.card(for: .gitea))
        XCTAssertNil(try GeneralConfigEditor.snapshot(from: String(contentsOf: url, encoding: .utf8)).gitea)
    }

    func testDeselectingAnUntouchedForgeJustHidesItsCard() async throws {
        let model = makeModel(reload: false)
        model.setSelected(true, for: .gitlab)
        // Let the card's async render settle so token state is known.
        try await Task.sleep(nanoseconds: 100_000_000)
        model.setSelected(false, for: .gitlab)
        XCTAssertNil(model.pendingDeselect, "nothing was saved, so no confirmation")
        XCTAssertNil(model.card(for: .gitlab))
    }

    func testCancellingTheDeselectKeepsTheCard() async throws {
        try GeneralConfigEditor.apply(.gitea(.init(instance: "https://git.example.com", scope: "team/repo")), to: url)
        let model = makeModel()
        await settle(model) { model.isSelected(.gitea) }
        model.setSelected(false, for: .gitea)
        model.cancelDeselect()
        XCTAssertNil(model.pendingDeselect)
        XCTAssertTrue(model.isSelected(.gitea))
        XCTAssertNotNil(model.card(for: .gitea))
    }

    func testConfirmDeselectRemovesTheGitLabAccount() async throws {
        try AccountsConfigEditor.add(
            AccountConfig(name: "gitlab", forge: .gitlab, scope: "acme/api"), to: url)
        var deleted: [ForgeID] = []
        let model = makeModel()
        model.deleteToken = { deleted.append($0) }
        await settle(model) { model.isSelected(.gitlab) }
        model.setSelected(false, for: .gitlab)
        model.confirmDeselect()
        let names = try AccountsConfigEditor.accounts(at: url).map(\.name)
        XCTAssertFalse(names.contains("gitlab"))
        XCTAssertEqual(deleted, [.gitlab])
    }

    // MARK: isConnected

    func testIsConnectedWithAGitLabOnlySetup() async throws {
        try AccountsConfigEditor.add(
            AccountConfig(name: "gitlab", forge: .gitlab, scope: "acme/api"), to: url)
        let model = makeModel()
        await settle(model) { model.isSelected(.gitlab) }
        let card = try XCTUnwrap(model.card(for: .gitlab))
        card.markTokenStoredForTesting(true)
        XCTAssertTrue(model.isConnected, "a GitLab-only setup can finish onboarding")
    }

    func testIsConnectedCountsASavedRepo() async throws {
        try "repo: \"acme/api\"\nlabels: [a]\n".write(to: url, atomically: true, encoding: .utf8)
        // A saved repo counts as connected once its forge also has a token:
        // the wizard gate needs both before the fleet can start.
        let model = makeModel(stored: [.github])
        await settle(model) { model.isConnected }
        XCTAssertTrue(model.isConnected, "saved repo + stored token counts as connected")
    }

    // MARK: Card behavior (through ForgeConnectionModel)

    func testGitLabCardCommitsScopeAndOptionalInstanceToTheAccountsSection() async throws {
        let model = makeModel(reload: false)
        model.setSelected(true, for: .gitlab)
        let card = try XCTUnwrap(model.card(for: .gitlab))
        // Let the card's async render settle before driving the form.
        try await Task.sleep(nanoseconds: 100_000_000)
        card.markTokenStoredForTesting(true)
        card.enterForTesting(instance: "", scope: "acme/platform/api")
        let account = try XCTUnwrap(AccountsConfigEditor.accounts(at: url).first { $0.forge == .gitlab })
        XCTAssertEqual(account.name, "gitlab")
        XCTAssertEqual(account.scope, "acme/platform/api")
        XCTAssertNil(account.instance, "blank instance → gitlab.com")
        XCTAssertTrue(model.isConnected)
    }

    func testGiteaCardNeedsServerAndScopeBeforeWriting() async throws {
        let model = makeModel()
        model.setSelected(true, for: .gitea)
        let card = try XCTUnwrap(model.card(for: .gitea))
        card.markTokenStoredForTesting(true)
        card.enterForTesting(instance: "https://git.example.com", scope: "team/repo")
        let gitea = try XCTUnwrap(
            try GeneralConfigEditor.snapshot(from: String(contentsOf: url, encoding: .utf8)).gitea)
        XCTAssertEqual(gitea.instance, "https://git.example.com")
        XCTAssertEqual(gitea.scope, "team/repo")

        // Half-filled: the section is not written.
        try GeneralConfigEditor.apply(.gitea(nil), to: url)
        card.enterForTesting(instance: "https://git.example.com", scope: "")
        XCTAssertNil(try GeneralConfigEditor.snapshot(from: String(contentsOf: url, encoding: .utf8)).gitea)
    }

    func testScopeFieldIsLockedUntilTheTokenIsStored() {
        let model = makeModel()
        model.setSelected(true, for: .github)
        let card = try! XCTUnwrap(model.card(for: .github))
        XCTAssertFalse(card.scopeEnabled)
        card.markTokenStoredForTesting(true)
        XCTAssertTrue(card.scopeEnabled)
    }

    func testRepoWriteRequiresAStoredToken() throws {
        let model = makeModel()
        model.setSelected(true, for: .github)
        let card = try! XCTUnwrap(model.card(for: .github))
        card.enterScopeForTesting("acme/api")
        XCTAssertEqual(
            try GeneralConfigEditor.snapshot(from: String(contentsOf: url, encoding: .utf8)).repo,
            "your-org/your-repo", "no token, so no repo is written")
        XCTAssertFalse(model.isConnected)
    }

    func testInvalidRepoIsRejectedAndNotWritten() throws {
        let model = makeModel()
        model.setSelected(true, for: .github)
        let card = try! XCTUnwrap(model.card(for: .github))
        card.markTokenStoredForTesting(true)
        card.enterScopeForTesting("a/b/c")
        XCTAssertEqual(
            try GeneralConfigEditor.snapshot(from: String(contentsOf: url, encoding: .utf8)).repo,
            "your-org/your-repo", "engine validation gates every write")
        XCTAssertTrue(card.status.text.contains("Not saved"))
    }

    func testGitHubProbeRunsForTheChosenScope() async throws {
        let model = makeModel(reload: false)
        model.setSelected(true, for: .github)
        let card = try XCTUnwrap(model.card(for: .github))
        // Let the initial async render settle so it cannot overwrite the
        // probe's verdict below.
        try await Task.sleep(nanoseconds: 100_000_000)
        var checked: [String] = []
        card.checkPermission = { scope, _ in
            checked.append(scope)
            return OrgPermissionProbe.Report(ok: false, message: "PAT lacks runner-management permission")
        }
        card.markTokenStoredForTesting(true)
        card.enterScopeForTesting("acme")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(checked, ["acme"])
        XCTAssertEqual(card.status.style, .error)
    }

    func testRequirementsHintPerForge() {
        let model = makeModel()
        model.setSelected(true, for: .gitlab)
        let gitlab = model.card(for: .gitlab)
        XCTAssertTrue(
            gitlab?.requirements.options.contains { $0.permissions.contains { $0.contains("create_runner") } }
                == true)
        model.setSelected(true, for: .forgejo)
        let forgejo = model.card(for: .forgejo)
        XCTAssertEqual(forgejo?.requirements.title.contains("Gitea"), true, "Forgejo shares the Gitea hint")
    }
}
