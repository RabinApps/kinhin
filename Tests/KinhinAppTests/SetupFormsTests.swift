import AppKit
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport
@testable import kinhin_app

@MainActor
final class SetupFormsTests: XCTestCase {
    private var configURL: URL!

    override func setUp() {
        super.setUp()
        configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-setupforms-\(UUID().uuidString).yaml")
        try? """
        repo: "your-org/your-repo"
        labels: [self-hosted, macOS]
        """.write(to: configURL, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: configURL)
        super.tearDown()
    }

    private func snapshot() throws -> GeneralConfigEditor.Snapshot {
        try GeneralConfigEditor.snapshot(from: String(contentsOf: configURL, encoding: .utf8))
    }

    private func connectModel() -> ConnectModel {
        let model = ConnectModel()
        model.configURL = configURL
        model.hasStoredToken = { _ in false }
        model.checkPermission = { _, _ in nil }
        model.reload()
        return model
    }

    func testChoosingARepoWritesItToConfig() throws {
        let model = connectModel()
        var changed = 0
        model.onChanged = { changed += 1 }
        model.markTokensStoredForTesting(github: true, gitea: false)
        model.enterGitHubRepoForTesting("acme/api")
        XCTAssertEqual(try snapshot().repo, "acme/api")
        XCTAssertEqual(changed, 1)
        XCTAssertTrue(model.isConnected)
    }

    /// Choosing a repo/org triggers the runner-permission check for exactly
    /// that scope, and its verdict replaces the generic "Now serving" line.
    func testChoosingARepoChecksRunnerPermissionForThatScope() async throws {
        let model = connectModel()
        // Let the form's initial async reload settle; it resets token state.
        try await Task.sleep(nanoseconds: 100_000_000)
        var checked: [(scope: String, token: String?)] = []
        model.checkPermission = { scope, token in
            checked.append((scope, token))
            return OrgPermissionProbe.Report(
                ok: false, message: "PAT lacks runner-management permission for '\(scope)'.")
        }
        model.markTokensStoredForTesting(github: true, gitea: false)
        model.enterGitHubRepoForTesting("acme")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(checked.map(\.scope), ["acme"])
        XCTAssertNil(checked.first?.token, "uses the stored token, never an empty one")
        XCTAssertEqual(model.githubStatus.style, .error)
        XCTAssertTrue(model.githubStatus.text.contains("lacks runner-management permission"))
    }

    /// Regression: after a token was saved the form still called the forge
    /// unconnected (wizard step 4 said so) and kept the repo picker locked.
    func testStoringATokenUnlocksTheRepoPickerAndConnects() async throws {
        try """
        repo: "acme/api"
        labels: [self-hosted]
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let model = connectModel()
        // Let the initial async reload (which reads the configured repo) settle.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(model.repoFieldsEnabledForTesting.github)

        model.didStoreToken(.github)
        XCTAssertTrue(model.repoFieldsEnabledForTesting.github, "the repo picker unlocks once a token is stored")
        XCTAssertTrue(model.isConnected, "token + configured repo counts as connected")
    }

    func testStoringATokenWritesARepoChosenBeforeConnecting() throws {
        let model = connectModel()
        model.githubRepo = "acme/web"
        model.didStoreToken(.github)
        XCTAssertEqual(try snapshot().repo, "acme/web")
        XCTAssertTrue(model.isConnected)
    }

    func testStoringAGiteaTokenWritesTheServerAndScope() throws {
        let model = connectModel()
        model.giteaInstance = "https://git.example.com"
        model.giteaScope = "team/repo"
        model.didStoreToken(.gitea)
        XCTAssertEqual(try snapshot().gitea?.scope, "team/repo")
        XCTAssertTrue(model.isConnected)
    }

    func testRepoCannotBeChosenBeforeTheForgeIsConnected() throws {
        let model = connectModel()
        model.enterGitHubRepoForTesting("acme/api")
        XCTAssertEqual(try snapshot().repo, "your-org/your-repo", "no token, so no repo is written")
        model.enterGiteaForTesting(instance: "https://git.example.com", scope: "team/repo")
        XCTAssertNil(try snapshot().gitea, "no Gitea token, so no gitea section is written")
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(model.repoFieldsEnabledForTesting.github, "the repo field is locked until connected")
        XCTAssertFalse(model.repoFieldsEnabledForTesting.gitea)
    }

    func testInvalidRepoIsRejectedAndNotWritten() throws {
        let model = connectModel()
        model.markTokensStoredForTesting(github: true, gitea: false)
        model.enterGitHubRepoForTesting("a/b/c")
        XCTAssertEqual(try snapshot().repo, "your-org/your-repo", "engine validation gates every write")
        XCTAssertTrue(model.githubStatus.text.contains("Not saved"))
    }

    func testGiteaInstanceAndScopeAreWrittenTogether() throws {
        let model = connectModel()
        model.markTokensStoredForTesting(github: false, gitea: true)
        model.enterGiteaForTesting(instance: "https://git.example.com", scope: "team/repo")
        let gitea = try XCTUnwrap(snapshot().gitea)
        XCTAssertEqual(gitea.instance, "https://git.example.com")
        XCTAssertEqual(gitea.scope, "team/repo")
    }

    func testGiteaNeedsBothServerAndScopeBeforeWriting() throws {
        let model = connectModel()
        model.markTokensStoredForTesting(github: false, gitea: true)
        model.enterGiteaForTesting(instance: "https://git.example.com", scope: "")
        XCTAssertNil(try snapshot().gitea, "a half-filled gitea: section would make the config invalid")
    }

    func testEitherForgeAloneCountsAsConnected() throws {
        let model = connectModel()
        XCTAssertFalse(model.isConnected)

        model.markTokensStoredForTesting(github: false, gitea: true)
        model.enterGiteaForTesting(instance: "https://git.example.com", scope: "team/repo")
        XCTAssertTrue(model.isConnected, "a Gitea-only setup can finish onboarding")
        XCTAssertEqual(try snapshot().repo, "your-org/your-repo", "no GitHub repo is required")
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
        try? "repo: \"acme/widgets\"\nlabels: [a]\n".write(to: configURL, atomically: true, encoding: .utf8)
        let quiet = MacToolsModel()
        quiet.configURL = configURL
        quiet.reload()
        XCTAssertNil(try snapshot().docker)
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
        model.onEdited = { edited += 1 }

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

    // MARK: Install flow

    private func installModel(
        shell: FakeShell, brew: String? = "/opt/homebrew/bin/brew", host: HostFacts = supportedHost
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

    private static let supportedHost = HostFacts(
        arm64: true, memoryGB: 16, osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
    )

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
        for _ in 0..<100 where shell.calls.isEmpty {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(shell.calls.first, ["/opt/homebrew/bin/brew", "install", "colima", "docker"])
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
