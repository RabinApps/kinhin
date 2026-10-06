import AppKit
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport
@testable import kinhin_app

@MainActor
final class SetupFormsTests: XCTestCase {
    private var configURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-setupforms-\(UUID().uuidString).yaml")
        try? """
        labels: [self-hosted, macOS]
        """.write(to: configURL, atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: configURL)
        try await super.tearDown()
    }

    private func snapshot() throws -> GeneralConfigEditor.Snapshot {
        try GeneralConfigEditor.snapshot(from: String(contentsOf: configURL, encoding: .utf8))
    }

    private func accounts() throws -> [AccountConfig] {
        try AccountsConfigEditor.accounts(at: configURL)
    }

    private func account(_ name: String) throws -> AccountConfig {
        try XCTUnwrap(try accounts().first { $0.name == name })
    }

    /// - Parameter reload: pass `false` in tests that select a forge by hand
    ///   and then suspend: the async render would otherwise run mid-test and
    ///   clobber the card's state (e.g. the probe's verdict).
    private func connectModel(stored: Set<ForgeID> = [], reload: Bool = true) -> ConnectModel {
        let model = ConnectModel()
        model.configURL = configURL
        model.hasStoredToken = { stored.contains($0) }
        model.loadToken = { _ in nil }
        model.checkPermission = { _, _, _ in nil }
        if reload { model.reload() }
        return model
    }

    /// Selects the forge and returns its card (created by selecting).
    private func card(_ model: ConnectModel, _ forge: ForgeID) throws -> ForgeConnectionModel {
        model.setSelected(true, for: forge)
        return try XCTUnwrap(model.card(for: forge))
    }

    func testChoosingARepoWritesItToConfig() throws {
        let model = connectModel()
        let github = try card(model, .github)
        var changed = 0
        model.onChanged = { changed += 1 }
        github.markTokenStoredForTesting(true)
        github.enterScopeForTesting("acme/api")
        XCTAssertEqual(try account("github").scope, "acme/api")
        XCTAssertEqual(changed, 1)
        XCTAssertTrue(model.isConnected)
    }

    /// Choosing a repo/org triggers the runner-permission check for exactly
    /// that scope, and its verdict replaces the generic "Now serving" line.
    func testChoosingARepoChecksRunnerPermissionForThatScope() async throws {
        let model = connectModel(reload: false)
        let github = try card(model, .github)
        // Let the initial async render settle so it cannot overwrite the
        // probe's verdict below.
        try await Task.sleep(nanoseconds: 100_000_000)
        var checked: [(scope: String, token: String?)] = []
        github.checkPermission = { scope, token, _ in
            checked.append((scope, token))
            return OrgPermissionProbe.Report(
                ok: false, message: "PAT lacks runner-management permission for '\(scope)'.")
        }
        github.markTokenStoredForTesting(true)
        github.enterScopeForTesting("acme")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(checked.map(\.scope), ["acme"])
        XCTAssertNil(checked.first?.token, "uses the stored token, never an empty one")
        XCTAssertEqual(github.status.style, .error)
        XCTAssertTrue(github.status.text.contains("lacks runner-management permission"))
    }

    /// Regression: after a token was saved the form still called the forge
    /// unconnected (wizard step 4 said so) and kept the repo picker locked.
    func testStoringATokenUnlocksTheRepoPickerAndConnects() async throws {
        try """
        accounts:
          - name: github
            forge: github
            scope: "acme/api"
        labels: [self-hosted]
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let model = connectModel()
        let github = try card(model, .github)
        // Let the initial async reload (which reads the configured repo) settle.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(github.scopeEnabled)

        github.didStoreToken()
        XCTAssertTrue(github.scopeEnabled, "the repo picker unlocks once a token is stored")
        XCTAssertTrue(model.isConnected, "token + configured repo counts as connected")
    }

    func testStoringATokenWritesARepoChosenBeforeConnecting() throws {
        let model = connectModel()
        let github = try card(model, .github)
        github.scope = "acme/web"
        github.didStoreToken()
        XCTAssertEqual(try account("github").scope, "acme/web")
        XCTAssertTrue(model.isConnected)
    }

    func testStoringAGiteaTokenWritesTheServerAndScope() throws {
        let model = connectModel()
        let gitea = try card(model, .gitea)
        gitea.instance = "https://git.example.com"
        gitea.scope = "team/repo"
        gitea.didStoreToken()
        XCTAssertEqual(try account("gitea").scope, "team/repo")
        XCTAssertTrue(model.isConnected)
    }

    func testRepoCannotBeChosenBeforeTheForgeIsConnected() throws {
        let model = connectModel()
        let github = try card(model, .github)
        github.enterScopeForTesting("acme/api")
        XCTAssertTrue(try accounts().isEmpty, "no token, so no account is written")
        let gitea = try card(model, .gitea)
        gitea.enterForTesting(instance: "https://git.example.com", scope: "team/repo")
        XCTAssertTrue(try accounts().isEmpty, "no Gitea token, so no account is written")
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(github.scopeEnabled, "the repo field is locked until connected")
        XCTAssertFalse(gitea.scopeEnabled)
    }

    func testInvalidRepoIsRejectedAndNotWritten() throws {
        let model = connectModel()
        let github = try card(model, .github)
        github.markTokenStoredForTesting(true)
        github.enterScopeForTesting("a/b/c")
        XCTAssertTrue(try accounts().isEmpty, "engine validation gates every write")
        XCTAssertTrue(github.status.text.contains("Not saved"))
    }

    func testGiteaInstanceAndScopeAreWrittenTogether() throws {
        let model = connectModel()
        let gitea = try card(model, .gitea)
        gitea.markTokenStoredForTesting(true)
        gitea.enterForTesting(instance: "https://git.example.com", scope: "team/repo")
        let giteaEntry = try account("gitea")
        XCTAssertEqual(giteaEntry.instance, "https://git.example.com")
        XCTAssertEqual(giteaEntry.scope, "team/repo")
    }

    func testGiteaNeedsBothServerAndScopeBeforeWriting() throws {
        let model = connectModel()
        let gitea = try card(model, .gitea)
        gitea.markTokenStoredForTesting(true)
        gitea.enterForTesting(instance: "https://git.example.com", scope: "")
        XCTAssertTrue(try accounts().isEmpty, "a half-filled account would make the config invalid")
    }

    func testEitherForgeAloneCountsAsConnected() throws {
        let model = connectModel()
        XCTAssertFalse(model.isConnected)

        let gitea = try card(model, .gitea)
        gitea.markTokenStoredForTesting(true)
        gitea.enterForTesting(instance: "https://git.example.com", scope: "team/repo")
        XCTAssertTrue(model.isConnected, "a Gitea-only setup can finish onboarding")
        XCTAssertFalse(try accounts().contains { $0.forge == .github }, "no GitHub account is required")
    }

    func testTartIsOptionalWhenALinuxRuntimeIsReady() throws {
        let model = MacToolsModel()
        model.configURL = configURL
        model.reload()
        var changes = 0
        model.onReadinessChanged = { changes += 1 }
        model.setTartReadyForTesting(false)
        XCTAssertFalse(model.isReady, "nothing to run jobs on yet")
        XCTAssertEqual(model.runsOnDescription, "nothing yet")

        // Docker is installed on the machine running the tests; only assert
        // the Linux path when it really is.
        guard Paths.findExecutable(named: "docker") != nil else { return }
        model.setDockerForTesting(true)
        XCTAssertTrue(model.isReady, "a Linux runtime alone is enough — tart is optional")
        XCTAssertTrue(model.runsOnDescription.hasPrefix("Linux jobs only (Docker)"), model.runsOnDescription)
        XCTAssertEqual(changes, 1)
        model.setDockerForTesting(false)
        XCTAssertFalse(model.isReady)
    }

    func testWizardTurnsOnAnInstalledLinuxRuntimeWhenTartIsMissing() throws {
        // Only meaningful on a host with Docker but without tart.
        guard !TartController.isInstalled(), Paths.findExecutable(named: "docker") != nil,
            Paths.findExecutable(named: "container") == nil
        else { return }
        let model = MacToolsModel()
        model.configURL = configURL
        model.autoEnableLinuxRuntime = true
        model.reload()
        XCTAssertNotNil(try snapshot().docker, "Docker was switched on so setup can finish")
        XCTAssertTrue(model.isReady)

        // The Accounts page (flag off) never changes choices on its own.
        try? FileManager.default.removeItem(at: configURL)
        try? """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: [a]
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let quiet = MacToolsModel()
        quiet.configURL = configURL
        quiet.reload()
        XCTAssertNil(try snapshot().docker)
    }

    func testExistingImageOffersARebuildThatAsksFirst() {
        let model = MacToolsModel()
        model.configURL = configURL
        XCTAssertEqual(model.imageButtonTitle, "Prepare image")
        model.setImagePresentForTesting(true)
        XCTAssertEqual(model.imageButtonTitle, "Rebuild image…")

        var asked = 0
        model.confirmRebuild = { _, _ in
            asked += 1
            return false
        }
        model.prepareImage()
        XCTAssertEqual(asked, 1)
        XCTAssertFalse(model.busy, "declining the confirmation must not start a rebuild")
    }

    func testSavingABaseImageSaysItNeedsARebuild() throws {
        let model = MacToolsModel()
        model.configURL = configURL
        model.reload()
        model.saveBaseImage("ghcr.io/cirruslabs/macos-tahoe-xcode:latest", for: .tart)
        XCTAssertTrue(model.busyLine.text.contains("Rebuild the image"))
    }

    func testAddingAndRemovingANamedImagePersists() throws {
        let model = MacToolsModel()
        model.configURL = configURL
        model.reload()
        model.addImage(name: " xcode ", baseImage: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest")
        XCTAssertEqual(try snapshot().images.map(\.name), ["xcode"])
        XCTAssertEqual(try snapshot().images.first?.baseImage, "ghcr.io/cirruslabs/macos-tahoe-xcode:latest")
        XCTAssertEqual(model.extraImages.map(\.name), ["xcode"])

        model.setImageBase(nil, for: "xcode")
        XCTAssertNil(try snapshot().images.first?.baseImage)

        model.setImageLabels("xcode, xcode-26", for: "xcode")
        XCTAssertEqual(try snapshot().images.first?.labels, ["xcode", "xcode-26"])
        XCTAssertEqual(model.extraImages.first?.labels, ["xcode", "xcode-26"])
        // A label the fleet already has would make every job match: refused, nothing written.
        model.setImageLabels("macos", for: "xcode")
        XCTAssertEqual(model.busyLine.style, .error)
        XCTAssertEqual(try snapshot().images.first?.labels, ["xcode", "xcode-26"])

        model.removeImage("xcode")
        XCTAssertTrue(try snapshot().images.isEmpty)
        XCTAssertTrue(model.extraImages.isEmpty)
    }

    /// Every add re-reads the config the previous one wrote (read → append →
    /// validate → write), so several named macOS images accumulate instead of
    /// replacing each other.
    func testAddingTwoNamedImagesPersistsBoth() throws {
        let model = MacToolsModel()
        model.configURL = configURL
        model.reload()
        model.addImage(name: "xcode", baseImage: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest")
        model.addImage(name: "web", baseImage: nil)
        XCTAssertEqual(try snapshot().images.map(\.name), ["xcode", "web"])
        XCTAssertEqual(model.extraImages.map(\.name), ["xcode", "web"])
        XCTAssertNotEqual(model.busyLine.style, .error, model.busyLine.text)
    }

    func testAddingAReservedImageNameIsRefusedAndSaid() throws {
        let model = MacToolsModel()
        model.configURL = configURL
        model.reload()
        model.addImage(name: "kinhin-xcode", baseImage: nil)
        XCTAssertTrue(try snapshot().images.isEmpty)
        XCTAssertEqual(model.busyLine.style, .error)
    }

    func testLinuxRuntimeTogglesPersist() throws {
        let model = MacToolsModel()
        model.configURL = configURL
        model.reload()
        model.setContainerForTesting(true)
        model.setDockerForTesting(true)
        XCTAssertNotNil(try snapshot().container)
        XCTAssertNotNil(try snapshot().docker)
        model.setDockerForTesting(false)
        XCTAssertNil(try snapshot().docker)
        XCTAssertNotNil(try snapshot().container)
    }

    func testCapacityWritesNothingUntilApplyThenOnce() throws {
        let model = CapacityModel()
        model.configURL = configURL
        model.reload()
        var edited = 0
        model.onChanged = { edited += 1 }

        let originalMax = try snapshot().maxRunners
        model.stage("max-runners", .maxRunners(6))
        model.stage("min-runners", .minRunners(2))
        model.stage("poll", .pollInterval(45))
        XCTAssertTrue(model.hasPendingChanges)
        XCTAssertEqual(try snapshot().maxRunners, originalMax, "nothing is written while editing")
        XCTAssertEqual(edited, 0)

        model.applyPending()
        let snap = try snapshot()
        XCTAssertEqual(snap.maxRunners, 6)
        XCTAssertEqual(snap.minRunners, 2)
        XCTAssertEqual(snap.pollInterval, 45)
        XCTAssertEqual(edited, 1, "one engine reload for the whole batch")
        XCTAssertFalse(model.hasPendingChanges)
    }

    func testCapacityApplyHandlesMinMaxOrdering() throws {
        // Min 4 first would transiently exceed the current Max of 1.
        let model = CapacityModel()
        model.configURL = configURL
        model.reload()
        model.stage("min-runners", .minRunners(4))
        model.stage("max-runners", .maxRunners(8))
        model.applyPending()
        let snap = try snapshot()
        XCTAssertEqual(snap.minRunners, 4)
        XCTAssertEqual(snap.maxRunners, 8)
    }

    func testCapacityRejectedEditStaysPendingWithAnError() throws {
        let model = CapacityModel()
        model.configURL = configURL
        model.reload()
        model.stage("min-runners", .minRunners(99))  // far above Max
        model.applyPending()
        XCTAssertTrue(model.hasPendingChanges, "a rejected edit is kept so it can be fixed")
        XCTAssertTrue(model.status.text.contains("Not applied"))
        XCTAssertEqual(try snapshot().minRunners, 0)
    }

    /// A config.yaml that doesn't parse is said on the form, not rendered
    /// as "nothing configured".
    func testMacToolsSaysWhenConfigIsUnreadable() throws {
        try "labels: [unterminated\n".write(to: configURL, atomically: true, encoding: .utf8)
        let model = MacToolsModel()
        model.configURL = configURL
        model.installedCheck = { _ in false }
        model.reload()
        XCTAssertEqual(model.busyLine.style, .error)
        XCTAssertTrue(model.busyLine.text.contains("config.yaml can't be read"), model.busyLine.text)
    }

    // MARK: - Install flow

    private func installModel(
        shell: FakeShell, brew: String? = "/opt/homebrew/bin/brew",
        host: HostFacts = HostFacts(
            arm64: true, memoryGB: 16,
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    ) -> MacToolsModel {
        let model = MacToolsModel()
        model.configURL = configURL
        model.installShell = shell
        model.brewPath = { brew }
        model.installedCheck = { _ in true }
        model.hostFacts = { host }
        model.reload()
        return model
    }

    func testCancellingTheInstallConfirmationRunsNothing() {
        let shell = FakeShell()
        let model = installModel(shell: shell)
        model.install(.docker)
        XCTAssertEqual(model.installOffer?.tool, .docker, "the user is always asked first")
        model.cancelInstall()
        XCTAssertNil(model.installOffer, "cancel closes the sheet")
        XCTAssertTrue(shell.calls.isEmpty, "cancel runs nothing")
    }

    func testConfirmedInstallRunsTheChosenOptionsCommands() async {
        let shell = FakeShell()
        let model = installModel(shell: shell)
        model.install(.docker)
        XCTAssertEqual(
            model.installOffer?.options.map(\.id), ["docker-desktop", "docker-orbstack", "docker-colima"],
            "all Docker options are offered")
        // The user picks Colima (captured before confirming: the sheet closes).
        let choice = model.installOffer?.options.first { $0.id == "docker-colima" }
        model.confirmInstall(choice!)
        XCTAssertNil(model.installOffer, "the sheet closes and the install starts")
        // reload() also starts a background container health check on the
        // same shell, so look for the install among the calls, not first.
        let install = ["/opt/homebrew/bin/brew", "install", "colima", "docker"]
        for _ in 0..<100 where !shell.calls.contains(install) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(shell.calls.contains(install), "\(shell.calls)")
        XCTAssertFalse(
            shell.calls.contains { $0.contains("orbstack") || $0.contains("--cask") }, "only the chosen option runs")
        // (The follow-up `colima start` is resolved from PATH after the real
        // install, so it isn't reachable with a fake shell.)
    }

    func testCopyCommandCopiesAndRunsNothing() {
        let shell = FakeShell()
        let model = installModel(shell: shell)
        model.install(.docker)
        let choice = model.installOffer?.options.first { $0.id == "docker-colima" }
        model.copyInstallCommand(choice!)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), choice?.commandLine)
        XCTAssertNil(model.installOffer, "the sheet closes; the copied command is the takeaway")
        XCTAssertTrue(shell.calls.isEmpty, "copying never runs the install")
    }

    func testMissingHomebrewExplainsInsteadOfAskingOrRunning() {
        let shell = FakeShell()
        let model = installModel(shell: shell, brew: nil)
        model.install(.appleContainer)
        XCTAssertEqual(model.missingBrewOffer?.tool, .appleContainer)
        XCTAssertNil(model.installOffer, "no confirmation sheet without Homebrew")
        XCTAssertTrue(shell.calls.isEmpty)
        model.cancelMissingBrew()
        XCTAssertNil(model.missingBrewOffer)
    }

    func testFailedInstallShowsTheErrorAndATerminalFallback() async {
        let shell = FakeShell()
        shell.failAll = "no space left"
        let model = installModel(shell: shell)
        model.install(.appleContainer)
        model.confirmInstall(model.installOffer!.options[0])
        // The install runs on a background task; wait for it to fail.
        for _ in 0..<100 where !model.busyLine.text.hasPrefix("Failed") {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let text = model.busyLine.text
        XCTAssertTrue(text.contains("Failed"), text)
        XCTAssertTrue(text.contains("no space left"))
        XCTAssertTrue(text.contains("brew install container"), "shows the command to run by hand")
    }

    func testUnsupportedMacExplainsInsteadOfAskingOrRunning() {
        let shell = FakeShell()
        let intel = HostFacts(
            arm64: false, memoryGB: 16,
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        let model = installModel(shell: shell, host: intel)
        var explained: String?
        model.explainUnsupported = { _, error in explained = error.localizedDescription }
        model.install(.appleContainer)
        XCTAssertTrue(explained?.contains("Apple silicon") ?? false)
        XCTAssertNil(model.installOffer, "nothing is offered that cannot run")
        XCTAssertTrue(shell.calls.isEmpty)
        if Paths.findExecutable(named: "container") == nil {
            XCTAssertFalse(model.containerInstallVisible, "no install button on a Mac that can't run it")
            XCTAssertTrue(model.containerLine.text.contains("not supported"))
        }
    }

    func testEveryInstallableToolHasAnInstallButtonWhenMissing() {
        let model = installModel(shell: FakeShell())
        XCTAssertTrue(model.tartInstallVisible || TartController.isInstalled())
        XCTAssertTrue(model.containerInstallVisible || Paths.findExecutable(named: "container") != nil)
        XCTAssertTrue(model.dockerInstallVisible || Paths.findExecutable(named: "docker") != nil)
    }
}
