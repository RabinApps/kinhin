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

    private func connectForm() -> ConnectFormViewController {
        let form = ConnectFormViewController()
        form.configURL = configURL
        form.hasStoredToken = { _ in false }
        form.model.checkPermission = { _, _ in nil }
        _ = form.view
        return form
    }

    func testChoosingARepoWritesItToConfig() throws {
        let form = connectForm()
        var changed = 0
        form.onChanged = { changed += 1 }
        form.markTokensStoredForTesting(github: true, gitea: false)
        form.enterGitHubRepoForTesting("acme/api")
        XCTAssertEqual(try snapshot().repo, "acme/api")
        XCTAssertEqual(changed, 1)
        XCTAssertTrue(form.isConnected)
    }

    /// Choosing a repo/org triggers the runner-permission check for exactly
    /// that scope, and its verdict replaces the generic "Now serving" line.
    func testChoosingARepoChecksRunnerPermissionForThatScope() async throws {
        let form = connectForm()
        // Let the form's initial async reload settle; it resets token state.
        try await Task.sleep(nanoseconds: 100_000_000)
        var checked: [(scope: String, token: String?)] = []
        form.model.checkPermission = { scope, token in
            checked.append((scope, token))
            return OrgPermissionProbe.Report(
                ok: false, message: "PAT lacks runner-management permission for '\(scope)'.")
        }
        form.markTokensStoredForTesting(github: true, gitea: false)
        form.enterGitHubRepoForTesting("acme")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(checked.map(\.scope), ["acme"])
        XCTAssertNil(checked.first?.token, "uses the stored token, never an empty one")
        XCTAssertEqual(form.model.githubStatus.style, .error)
        XCTAssertTrue(form.model.githubStatus.text.contains("lacks runner-management permission"))
    }

    /// Regression: after a token was saved the form still called the forge
    /// unconnected (wizard step 4 said so) and kept the repo picker locked.
    func testStoringATokenUnlocksTheRepoPickerAndConnects() async throws {
        try """
        repo: "acme/api"
        labels: [self-hosted]
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let form = connectForm()
        // Let the initial async reload (which reads the configured repo) settle.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(form.isConnected)
        XCTAssertFalse(form.repoFieldsEnabledForTesting.github)

        form.didStoreTokenForTesting(.github)
        XCTAssertTrue(form.repoFieldsEnabledForTesting.github, "the repo picker unlocks once a token is stored")
        XCTAssertTrue(form.isConnected, "token + configured repo counts as connected")
    }

    func testStoringATokenWritesARepoChosenBeforeConnecting() throws {
        let form = connectForm()
        form.model.githubRepo = "acme/web"
        form.didStoreTokenForTesting(.github)
        XCTAssertEqual(try snapshot().repo, "acme/web")
        XCTAssertTrue(form.isConnected)
    }

    func testStoringAGiteaTokenWritesTheServerAndScope() throws {
        let form = connectForm()
        form.model.giteaInstance = "https://git.example.com"
        form.model.giteaScope = "team/repo"
        form.didStoreTokenForTesting(.gitea)
        XCTAssertEqual(try snapshot().gitea?.scope, "team/repo")
        XCTAssertTrue(form.isConnected)
    }

    func testRepoCannotBeChosenBeforeTheForgeIsConnected() throws {
        let form = connectForm()
        form.enterGitHubRepoForTesting("acme/api")
        XCTAssertEqual(try snapshot().repo, "your-org/your-repo", "no token, so no repo is written")
        form.enterGiteaForTesting(instance: "https://git.example.com", scope: "team/repo")
        XCTAssertNil(try snapshot().gitea, "no Gitea token, so no gitea section is written")
        XCTAssertFalse(form.isConnected)
        XCTAssertFalse(form.repoFieldsEnabledForTesting.github, "the repo field is locked until connected")
        XCTAssertFalse(form.repoFieldsEnabledForTesting.gitea)
    }

    func testInvalidRepoIsRejectedAndNotWritten() throws {
        let form = connectForm()
        form.markTokensStoredForTesting(github: true, gitea: false)
        form.enterGitHubRepoForTesting("a/b/c")
        XCTAssertEqual(try snapshot().repo, "your-org/your-repo", "engine validation gates every write")
        XCTAssertTrue(form.model.githubStatus.text.contains("Not saved"))
    }

    func testGiteaInstanceAndScopeAreWrittenTogether() throws {
        let form = connectForm()
        form.markTokensStoredForTesting(github: false, gitea: true)
        form.enterGiteaForTesting(instance: "https://git.example.com", scope: "team/repo")
        let gitea = try XCTUnwrap(snapshot().gitea)
        XCTAssertEqual(gitea.instance, "https://git.example.com")
        XCTAssertEqual(gitea.scope, "team/repo")
    }

    func testGiteaNeedsBothServerAndScopeBeforeWriting() throws {
        let form = connectForm()
        form.markTokensStoredForTesting(github: false, gitea: true)
        form.enterGiteaForTesting(instance: "https://git.example.com", scope: "")
        XCTAssertNil(try snapshot().gitea, "a half-filled gitea: section would make the config invalid")
    }

    func testEitherForgeAloneCountsAsConnected() throws {
        let form = connectForm()
        XCTAssertFalse(form.isConnected)

        form.markTokensStoredForTesting(github: false, gitea: true)
        form.enterGiteaForTesting(instance: "https://git.example.com", scope: "team/repo")
        XCTAssertTrue(form.isConnected, "a Gitea-only setup can finish onboarding")
        XCTAssertEqual(try snapshot().repo, "your-org/your-repo", "no GitHub repo is required")
    }

    func testTartIsOptionalWhenALinuxRuntimeIsReady() throws {
        let form = MacToolsFormViewController()
        form.configURL = configURL
        _ = form.view
        var changes = 0
        form.onReadinessChanged = { changes += 1 }
        form.setTartReadyForTesting(false)
        XCTAssertFalse(form.isReady, "nothing to run jobs on yet")
        XCTAssertEqual(form.runsOnDescription, "nothing yet")

        // Docker is installed on the machine running the tests; only assert
        // the Linux path when it really is.
        guard Paths.findExecutable(named: "docker") != nil else { return }
        form.setDockerForTesting(true)
        XCTAssertTrue(form.isReady, "a Linux runtime alone is enough — tart is optional")
        XCTAssertTrue(form.runsOnDescription.hasPrefix("Linux jobs only (Docker)"), form.runsOnDescription)
        XCTAssertEqual(changes, 1)
        form.setDockerForTesting(false)
        XCTAssertFalse(form.isReady)
    }

    func testWizardTurnsOnAnInstalledLinuxRuntimeWhenTartIsMissing() throws {
        // Only meaningful on a host with Docker but without tart.
        guard !TartController.isInstalled(), Paths.findExecutable(named: "docker") != nil,
            Paths.findExecutable(named: "container") == nil
        else { return }
        let form = MacToolsFormViewController()
        form.configURL = configURL
        form.autoEnableLinuxRuntime = true
        _ = form.view
        XCTAssertNotNil(try snapshot().docker, "Docker was switched on so setup can finish")
        XCTAssertTrue(form.isReady)

        // The Accounts page (flag off) never changes choices on its own.
        try? FileManager.default.removeItem(at: configURL)
        try? "repo: \"acme/widgets\"\nlabels: [a]\n".write(to: configURL, atomically: true, encoding: .utf8)
        let quiet = MacToolsFormViewController()
        quiet.configURL = configURL
        _ = quiet.view
        XCTAssertNil(try snapshot().docker)
    }

    func testLinuxRuntimeTogglesPersist() throws {
        let form = MacToolsFormViewController()
        form.configURL = configURL
        _ = form.view
        form.setContainerForTesting(true)
        form.setDockerForTesting(true)
        XCTAssertNotNil(try snapshot().container)
        XCTAssertNotNil(try snapshot().docker)
        form.setDockerForTesting(false)
        XCTAssertNil(try snapshot().docker)
        XCTAssertNotNil(try snapshot().container)
    }

    func testCapacityWritesNothingUntilApplyThenOnce() throws {
        let form = ConfigTabViewController()
        form.configURL = configURL
        _ = form.view
        var edited = 0
        form.onEdited = { edited += 1 }

        let originalMax = try snapshot().maxRunners
        form.stageForTesting(.maxRunners(6), id: "max-runners")
        form.stageForTesting(.minRunners(2), id: "min-runners")
        form.stageForTesting(.pollInterval(45), id: "poll")
        XCTAssertTrue(form.hasPendingChanges)
        XCTAssertEqual(try snapshot().maxRunners, originalMax, "nothing is written while editing")
        XCTAssertEqual(edited, 0)

        form.applyPending()
        let snap = try snapshot()
        XCTAssertEqual(snap.maxRunners, 6)
        XCTAssertEqual(snap.minRunners, 2)
        XCTAssertEqual(snap.pollInterval, 45)
        XCTAssertEqual(edited, 1, "one engine reload for the whole batch")
        XCTAssertFalse(form.hasPendingChanges)
    }

    func testCapacityApplyHandlesMinMaxOrdering() throws {
        // Min 4 first would transiently exceed the current Max of 1.
        let form = ConfigTabViewController()
        form.configURL = configURL
        _ = form.view
        form.stageForTesting(.minRunners(4), id: "min-runners")
        form.stageForTesting(.maxRunners(8), id: "max-runners")
        form.applyPending()
        let snap = try snapshot()
        XCTAssertEqual(snap.minRunners, 4)
        XCTAssertEqual(snap.maxRunners, 8)
    }

    func testCapacityRejectedEditStaysPendingWithAnError() throws {
        let form = ConfigTabViewController()
        form.configURL = configURL
        _ = form.view
        form.stageForTesting(.minRunners(99), id: "min-runners")  // far above Max
        form.applyPending()
        XCTAssertTrue(form.hasPendingChanges, "a rejected edit is kept so it can be fixed")
        XCTAssertTrue(allText(in: form.view).contains("Not applied"))
        XCTAssertEqual(try snapshot().minRunners, 0)
    }

    private func allText(in view: NSView) -> String {
        var out: [String] = []
        func walk(_ v: NSView) {
            if let t = v as? NSTextField { out.append(t.stringValue) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return out.joined(separator: "\n")
    }

    // MARK: Install flow

    private func installForm(shell: FakeShell, brew: String? = "/opt/homebrew/bin/brew")
        -> MacToolsFormViewController
    {
        let form = MacToolsFormViewController()
        form.configURL = configURL
        form.installShell = shell
        form.brewPath = { brew }
        form.installedCheck = { _ in true }
        _ = form.view
        return form
    }

    func testCancellingTheInstallConfirmationRunsNothing() {
        let shell = FakeShell()
        let form = installForm(shell: shell)
        var asked: [InstallableTool] = []
        form.confirmInstall = { tool, _ in
            asked.append(tool); return nil
        }
        XCTAssertNil(form.install(.docker))
        XCTAssertEqual(asked, [.docker], "the user is always asked first")
        XCTAssertTrue(shell.calls.isEmpty)
    }

    func testConfirmedInstallRunsTheChosenOptionsCommands() async {
        let shell = FakeShell()
        let form = installForm(shell: shell)
        var offered: [String] = []
        form.confirmInstall = { _, options in
            offered = options.map(\.id)
            return options.first { $0.id == "docker-colima" }  // the user picks Colima
        }
        await form.install(.docker)?.value
        XCTAssertEqual(
            offered, ["docker-desktop", "docker-orbstack", "docker-colima"], "all Docker options are offered")
        XCTAssertEqual(shell.calls.first, ["/opt/homebrew/bin/brew", "install", "colima", "docker"])
        // (The follow-up `colima start` is resolved from PATH after the real
        // install, so it isn't reachable with a fake shell.)
    }

    func testMissingHomebrewExplainsInsteadOfAskingOrRunning() {
        let shell = FakeShell()
        let form = installForm(shell: shell, brew: nil)
        var explained: InstallableTool?
        var confirmed = false
        form.explainMissingBrew = { tool, _ in explained = tool }
        form.confirmInstall = { _, _ in
            confirmed = true; return nil
        }
        XCTAssertNil(form.install(.appleContainer))
        XCTAssertEqual(explained, .appleContainer)
        XCTAssertFalse(confirmed)
        XCTAssertTrue(shell.calls.isEmpty)
    }

    func testFailedInstallShowsTheErrorAndATerminalFallback() async {
        let shell = FakeShell()
        shell.failAll = "no space left"
        let form = installForm(shell: shell)
        form.confirmInstall = { _, options in options.first }
        let task = form.install(.appleContainer)
        await task?.value
        try? await Task.sleep(nanoseconds: 100_000_000)
        let text = form.model.busyLine.text
        XCTAssertTrue(text.contains("Failed"), text)
        XCTAssertTrue(text.contains("no space left"))
        XCTAssertTrue(text.contains("brew install container"), "shows the command to run by hand")
    }

    func testEveryInstallableToolHasAnInstallButtonWhenMissing() {
        let form = installForm(shell: FakeShell())
        let model = form.model
        XCTAssertTrue(model.tartInstallVisible || TartController.isInstalled())
        XCTAssertTrue(model.containerInstallVisible || Paths.findExecutable(named: "container") != nil)
        XCTAssertTrue(model.dockerInstallVisible || Paths.findExecutable(named: "docker") != nil)
    }
}
