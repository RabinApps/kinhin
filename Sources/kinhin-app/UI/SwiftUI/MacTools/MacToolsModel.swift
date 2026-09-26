import AppKit
import KinhinKit
import Observation

/// State and actions behind the "This Mac" form: what kinhin runs jobs on,
/// with real actions instead of instructions. macOS jobs need tart and a
/// prepared base image (both can be fixed here); Linux jobs can optionally
/// use Apple container or Docker (toggling writes the config section with
/// sensible defaults).
@MainActor
@Observable
final class MacToolsModel {
    typealias Line = StatusLine

    /// The config file this form edits (tests point it at a scratch file).
    var configURL: URL = Paths.config
    @ObservationIgnored var onChanged: (() -> Void)?

    /// True when the fleet has something to run jobs on: tart with its base
    /// image, or an enabled Linux runtime (Docker / Apple container) that is
    /// actually installed. Tart is optional — a Linux-only Mac is a valid setup.
    private(set) var isReady = false
    @ObservationIgnored var onReadinessChanged: (() -> Void)?

    /// The wizard sets this: when tart isn't installed and no Linux runtime is
    /// on, switch on an installed Docker / Apple container so setup can
    /// finish, and say so. (The Accounts page leaves choices alone.)
    @ObservationIgnored var autoEnableLinuxRuntime = false

    private var tartReady = false
    /// Enabled *and* installed Linux runtimes, by display name.
    private(set) var activeLinuxRuntimes: [String] = []

    /// Plain-language summary of what jobs can run here (for the final step).
    var runsOnDescription: String {
        switch (tartReady, activeLinuxRuntimes.isEmpty) {
        case (true, true): return "macOS jobs (tart)"
        case (true, false): return "macOS jobs (tart) and Linux jobs (\(activeLinuxRuntimes.joined(separator: ", ")))"
        case (false, false):
            return
                "Linux jobs only (\(activeLinuxRuntimes.joined(separator: ", "))) — macOS jobs need tart, which isn't set up"
        case (false, true): return "nothing yet"
        }
    }

    // MARK: Display state

    private(set) var tartLine = Line(text: "Checking…")
    private(set) var tartInstallVisible = false
    private(set) var imageLine = Line(text: "")
    private(set) var imageButtonVisible = false
    /// A long-running action (install, prepare image) is in flight.
    private(set) var busy = false
    private(set) var busyLine = Line(text: "")

    private(set) var containerOn = false
    private(set) var dockerOn = false
    private(set) var containerLine = Line(text: "")
    private(set) var dockerLine = Line(text: "")
    private(set) var containerInstallVisible = false
    private(set) var dockerInstallVisible = false
    private(set) var containerInstallTitle = "Install…"
    /// Base image each Linux runtime's image is baked on (nil = default);
    /// shown while the runtime is enabled.
    private(set) var containerBaseImage: String?
    private(set) var dockerBaseImage: String?
    private(set) var dockerPlatform: LinuxPlatform = .arm64

    /// Installed but its background service isn't running: offer to start it
    /// (a fresh install leaves it stopped).
    private var containerServiceNeedsStart = false

    // MARK: Injectable seams

    /// Asks the user to confirm an install and pick a method. Returns the
    /// chosen option, or nil when cancelled. Injectable so tests never open a
    /// modal alert or run Homebrew.
    @ObservationIgnored var confirmInstall: (InstallableTool, [InstallOption]) -> InstallOption? = { tool, options in
        InstallDialogs.presentInstallConfirmation(tool: tool, options: options)
    }
    /// Shown instead of the confirmation when Homebrew is missing.
    @ObservationIgnored var explainMissingBrew: (InstallableTool, [InstallOption]) -> Void = { tool, options in
        InstallDialogs.presentMissingBrew(tool: tool, options: options)
    }
    @ObservationIgnored var installShell: ShellRunning = Shell()
    /// Whether a tool is installed afterwards (real PATH lookup by default).
    @ObservationIgnored var installedCheck: @Sendable (InstallableTool) -> Bool = { $0.isInstalled }
    @ObservationIgnored var brewPath: () -> String? = { RuntimeInstaller.brewPath }
    /// The Mac install options are judged against (real probe by default).
    @ObservationIgnored var hostFacts: () -> HostFacts = { .current() }
    /// Shown instead of the confirmation when no option can run on this Mac.
    @ObservationIgnored var explainUnsupported: (InstallableTool, Error) -> Void = { tool, error in
        AlertKit.present(error: error, title: "\(tool.title) can't run on this Mac")
    }

    // MARK: State

    func reload() {
        let snapshot = ConfigStore.snapshotOrLog(at: configURL)
        containerOn = snapshot?.container != nil
        dockerOn = snapshot?.docker != nil
        refreshBaseImages()
        let containerInstalled = Paths.findExecutable(named: "container") != nil
        let dockerInstalled = Paths.findExecutable(named: "docker") != nil
        recomputeReadiness()
        // Don't offer an install that can't run here; say why instead.
        let host = hostFacts()
        let containerBlocked = HostRequirements.blockingReason(for: .appleContainer, on: host)
        let dockerBlocked = HostRequirements.blockingReason(for: .docker, on: host)
        containerInstallVisible = !containerInstalled && containerBlocked == nil
        containerInstallTitle = "Install…"
        containerServiceNeedsStart = false
        dockerInstallVisible = !dockerInstalled && dockerBlocked == nil
        containerLine = Self.installLine(installed: containerInstalled, blocked: containerBlocked)
        dockerLine = Self.installLine(installed: dockerInstalled, blocked: dockerBlocked)

        let image = snapshot?.image ?? "tahoe-base"
        let tartInstalled = TartController.isInstalled()
        if autoEnableLinuxRuntime, !tartInstalled, !containerOn, !dockerOn {
            if dockerInstalled {
                setDocker(true)
                noteAutoEnabled("Docker")
            } else if containerInstalled {
                setContainer(true)
                noteAutoEnabled("Apple container")
            }
        }
        tartLine = Line(
            text: tartInstalled ? "installed ✓" : "not installed", style: tartInstalled ? .secondary : .warn)
        tartInstallVisible = !tartInstalled
        if containerInstalled { checkContainerService() }
        guard tartInstalled else {
            imageLine = Line(text: "needs tart first")
            imageButtonVisible = false
            setTartReady(false)
            return
        }
        imageLine = Line(text: "checking \(image)…")
        imageButtonVisible = false
        Task { [weak self] in
            let present = await Task.detached { () -> Bool in
                guard let tart = try? TartController() else { return false }
                return ((try? await tart.list()) ?? []).contains { $0.name == image }
            }.value
            guard let self else { return }
            self.imageLine = Line(
                text: present ? "\(image) ready ✓" : "\(image) not prepared yet — takes a while, once",
                style: present ? .secondary : .warn)
            self.imageButtonVisible = !present
            self.setTartReady(present)
        }
    }

    private func noteAutoEnabled(_ name: String) {
        busyLine = Line(text: "tart isn't installed, so \(name) is on for Linux jobs. Change it below any time.")
    }

    private func setTartReady(_ ready: Bool) {
        tartReady = ready
        recomputeReadiness()
    }

    /// Re-derives readiness from tart + the Linux toggles. Toggling a runtime
    /// on or off changes it immediately (no reload needed).
    private func recomputeReadiness() {
        var active: [String] = []
        if containerOn, Paths.findExecutable(named: "container") != nil { active.append("Apple container") }
        if dockerOn, Paths.findExecutable(named: "docker") != nil { active.append("Docker") }
        activeLinuxRuntimes = active
        let ready = tartReady || !active.isEmpty
        let changed = ready != isReady
        isReady = ready
        if changed { onReadinessChanged?() }
    }

    /// Re-reads the saved base image for each runtime.
    private func refreshBaseImages() {
        let snapshot = ConfigStore.snapshotOrLog(at: configURL)
        containerBaseImage = snapshot?.baseImage(for: .appleContainer)
        dockerBaseImage = snapshot?.baseImage(for: .docker)
        dockerPlatform = snapshot?.dockerPlatform ?? .arm64
    }

    func saveDockerPlatform(_ platform: LinuxPlatform) {
        do {
            try GeneralConfigEditor.setDockerPlatform(platform, at: configURL)
            refreshBaseImages()
            onChanged?()
        } catch {
            busyLine = Line(text: "Not saved — \(error.localizedDescription)", style: .error)
            refreshBaseImages()
        }
    }

    func saveBaseImage(_ value: String?, for runtime: RuntimeID) {
        do {
            try GeneralConfigEditor.setBaseImage(value, for: runtime, at: configURL)
            refreshBaseImages()
            onChanged?()
        } catch {
            busyLine = Line(text: "Not saved — \(error.localizedDescription)", style: .error)
            refreshBaseImages()
        }
    }

    // MARK: Actions

    @discardableResult
    private func run(_ title: String, _ body: @escaping @Sendable () async throws -> Void) -> Task<Void, Never> {
        busy = true
        busyLine = Line(text: title)
        return Task { [weak self] in
            do {
                try await body()
                self?.busyLine = Line(text: "")
            } catch {
                self?.busyLine = Line(text: "Failed — \(error.localizedDescription)", style: .error)
            }
            self?.busy = false
            self?.reload()
        }
    }

    private static func installLine(installed: Bool, blocked: String?) -> Line {
        if installed { return Line(text: "installed ✓") }
        if let blocked { return Line(text: "not supported — \(blocked)", style: .warn) }
        return Line(text: "not installed")
    }

    func installTart() { install(.tart) }

    func installContainer() {
        if containerServiceNeedsStart { startContainerService() } else { install(.appleContainer) }
    }

    func installDocker() { install(.docker) }

    private func checkContainerService() {
        let shell = installShell
        Task { [weak self] in
            let ready = await Task.detached { await AppleContainerRuntime(shell: shell).health().isReady }.value
            guard let self, !ready, self.containerLine.text.hasPrefix("installed") else { return }
            self.containerServiceNeedsStart = true
            self.containerLine = Line(text: "installed, but its service isn't running", style: .warn)
            self.containerInstallTitle = "Start service"
            self.containerInstallVisible = true
        }
    }

    @discardableResult
    func startContainerService() -> Task<Void, Never> {
        let shell = installShell
        return run("Starting the Apple container service…") {
            try await SetupRepairRunner.startContainerSystem(shell: shell)
        }
    }

    /// Confirm → install → re-check. Nothing runs without an explicit yes, and
    /// a missing Homebrew gets an explanation instead of a failing command.
    @discardableResult
    func install(_ tool: InstallableTool) -> Task<Void, Never>? {
        let host = hostFacts()
        do {
            try HostRequirements.ensureSupported(tool, on: host)
        } catch {
            explainUnsupported(tool, error)
            return nil
        }
        let options = HostRequirements.offeredOptions(for: tool, on: host)
        guard brewPath() != nil || options.contains(where: { !$0.needsBrew }) else {
            explainMissingBrew(tool, options)
            return nil
        }
        guard let choice = confirmInstall(tool, options) else { return nil }
        let shell = installShell
        let brew = brewPath()
        let installed = installedCheck
        let name = tool.title
        let task = run("Installing \(name)… this can take several minutes.") {
            try await RuntimeInstaller.install(
                choice, tool: tool, shell: shell, brew: brew, host: host, isInstalled: installed)
        }
        // On failure, tell the user how to do it by hand.
        Task { [weak self] in
            await task.value
            guard let self, self.busyLine.text.hasPrefix("Failed") else { return }
            self.busyLine.text += "\nYou can also run this in Terminal: \(choice.commandLine)"
        }
        return task
    }

    func prepareImage() {
        run("Preparing the runner image — this takes a while, but only once…") {
            let cfg = try ConfigLoader.load()
            let tart = try TartController(configuredPath: cfg.tartPath)
            var options = ImagePreparer.Options()
            options.provisionScriptPath = cfg.provisionScript
            options.toolchains = cfg.toolchains
            try await ImagePreparer(tart: tart, ssh: SSHExecutor()).run(options)
        }
    }

    func setContainer(_ on: Bool) {
        let snap = ConfigStore.snapshotOrLog(at: configURL)
        containerOn = on
        write(
            .container(on ? (snap?.container ?? .init(image: "kinhin-ci-linux", cpus: 4, memoryGB: 8)) : nil),
            revert: { $0.containerOn = !on })
    }

    func setDocker(_ on: Bool) {
        let snap = ConfigStore.snapshotOrLog(at: configURL)
        dockerOn = on
        write(
            .docker(on ? (snap?.docker ?? .init(image: "kinhin-ci-linux", cpus: 2, memoryGB: 4, maxSlots: 8)) : nil),
            revert: { $0.dockerOn = !on })
    }

    private func write(_ field: GeneralConfigEditor.Field, revert: (MacToolsModel) -> Void) {
        do {
            try GeneralConfigEditor.apply(field, to: configURL)
            recomputeReadiness()
            refreshBaseImages()
            onChanged?()
        } catch {
            revert(self)
            recomputeReadiness()
            busyLine = Line(text: "Not saved — \(error.localizedDescription)", style: .error)
        }
    }

    // MARK: Test hooks

    func setTartReadyForTesting(_ ready: Bool) { setTartReady(ready) }
    func setContainerForTesting(_ on: Bool) { setContainer(on) }
    func setDockerForTesting(_ on: Bool) { setDocker(on) }
}
