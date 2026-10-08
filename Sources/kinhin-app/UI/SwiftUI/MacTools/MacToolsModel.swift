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
final class MacToolsModel: ConfigFormModel {
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

    /// The readiness rule's inputs and derived answers (see `MacReadiness`).
    private var readiness = MacReadiness()
    /// Enabled *and* installed Linux runtimes, by display name.
    var activeLinuxRuntimes: [String] { readiness.activeLinuxRuntimes }
    /// Plain-language summary of what jobs can run here (for the final step).
    var runsOnDescription: String { readiness.runsOnDescription }

    // MARK: - Display state

    private(set) var tartLine = Line(text: "Checking…")
    private(set) var tartInstallVisible = false
    /// tart is installed on this Mac (the Linux row's checkbox needs it).
    private(set) var tartInstalled = false

    /// Whether the "More images" (named base images) block is offered. Tart is
    /// what bakes them, so tart being installed is the only requirement: the
    /// primary base image being a Linux one must not take the block away —
    /// named images with distinct labels are exactly how a mixed macOS +
    /// Linux tart fleet gets its macOS images back.
    var offersNamedImages: Bool { tartInstalled }

    private(set) var imageLine = Line(text: "")
    private(set) var imageButtonVisible = false
    /// The prepared tart image exists, so the button rebuilds it (a changed
    /// base image only takes effect through a rebuild).
    private(set) var imagePresent = false
    /// The tart image is being baked right now. The wizard lets Start through
    /// meanwhile: the bake keeps running in the background.
    private(set) var isPreparingImage = false
    var imageButtonTitle: String { imagePresent ? "Rebuild image…" : "Prepare image" }
    private(set) var containerOn = false
    private(set) var dockerOn = false
    private(set) var containerLine = Line(text: "")
    private(set) var dockerLine = Line(text: "")
    private(set) var containerInstallVisible = false
    private(set) var dockerInstallVisible = false
    private(set) var containerInstallTitle = "Install…"
    /// Base image each runtime's image is baked on (nil = default); the
    /// tart value is what `image prepare` starts from.
    internal(set) var tartBaseImage: String?
    /// The fleet's `labels:` as saved (what runners advertise to the forge).
    internal(set) var fleetLabels: [String] = []
    internal(set) var containerBaseImage: String?
    internal(set) var dockerBaseImage: String?
    internal(set) var dockerPlatform: LinuxPlatform = .arm64

    /// Installed but its background service isn't running: offer to start it
    /// (a fresh install leaves it stopped).
    private var containerServiceNeedsStart = false

    // MARK: - Collaborators

    /// Test seams (shell, host probe, confirmations) shared with the collaborators.
    @ObservationIgnored let seams = MacToolsSeams()
    /// The install flow and the busy/progress state of long actions.
    @ObservationIgnored private(set) lazy var installs = InstallCoordinator(seams: seams) { [weak self] in
        self?.reload()
    }
    /// The extra named macOS images (`images:`).
    @ObservationIgnored private(set) lazy var namedImages = NamedImagesModel(owner: self)

    // MARK: - Forwarded busy state (the form and the sibling forms read these)

    var busy: Bool { installs.busy }
    var busyLine: Line { installs.busyLine }
    var runningTask: Task<Void, Never>? { installs.runningTask }
    var installOffer: InstallOffer? {
        get { installs.installOffer }
        set { installs.installOffer = newValue }
    }
    var missingBrewOffer: MissingBrewOffer? {
        get { installs.missingBrewOffer }
        set { installs.missingBrewOffer = newValue }
    }
    var linuxSetupOffer: LinuxRuntimeSetup.Offer? {
        get { installs.linuxSetupOffer }
        set { installs.linuxSetupOffer = newValue }
    }
    func cancelRunning() { installs.cancelRunning() }
    func install(_ tool: InstallableTool) { installs.install(tool) }
    @discardableResult
    func run(
        _ title: String, cancelledLine: String = "Cancelled",
        _ body: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, Never> { installs.run(title, cancelledLine: cancelledLine, body) }

    // MARK: - State

    func reload() {
        // A broken config.yaml is said here, not rendered as the defaults
        // (the toggles below would otherwise read "off" and invite a write).
        let snapshot: GeneralConfigEditor.Snapshot?
        let configReadable: Bool
        do {
            snapshot = try ConfigStore.snapshot(at: configURL)
            configReadable = true
        } catch {
            snapshot = nil
            configReadable = false
            installs.busyLine = .unreadableConfig(error)
        }
        containerOn = snapshot?.container != nil
        dockerOn = snapshot?.docker != nil
        refreshBaseImages(from: snapshot)
        let containerInstalled = Paths.findExecutable(named: "container") != nil
        let dockerInstalled = Paths.findExecutable(named: "docker") != nil
        recomputeReadiness()
        // Don't offer an install that can't run here; say why instead.
        let host = seams.hostFacts()
        let containerBlocked = HostRequirements.blockingReason(for: .appleContainer, on: host)
        let dockerBlocked = HostRequirements.blockingReason(for: .docker, on: host)
        containerInstallVisible = !containerInstalled && containerBlocked == nil
        containerInstallTitle = "Install…"
        containerServiceNeedsStart = false
        dockerInstallVisible = !dockerInstalled && dockerBlocked == nil
        containerLine = Self.installLine(installed: containerInstalled, blocked: containerBlocked)
        dockerLine = Self.installLine(installed: dockerInstalled, blocked: dockerBlocked)

        let image = snapshot?.image ?? "tahoe-base"
        let extra = snapshot?.images ?? []
        namedImages.rows = extra.map {
            .init(name: $0.name, baseImage: $0.baseImage, labels: $0.labels ?? [], present: false)
        }
        // `tart_path:` is authoritative, exactly like the CLI, doctor and the
        // daemon: a configured binary that is not there reads as missing (the
        // form offers to install), and a tart outside the trusted directories
        // is still found when the config points at it.
        let tartPath = snapshot?.tartPath
        let tartInstalled = TartController.isInstalled(configuredPath: tartPath)
        if autoEnableLinuxRuntime, configReadable, !tartInstalled, !containerOn, !dockerOn {
            if dockerInstalled {
                setDocker(true)
                noteAutoEnabled("Docker")
            } else if containerInstalled {
                setContainer(true)
                noteAutoEnabled("Apple container")
            }
        }
        tartLine = Line(
            text: Self.tartStatus(installed: tartInstalled, configuredPath: tartPath),
            style: tartInstalled ? .secondary : .warn)
        tartInstallVisible = !tartInstalled
        self.tartInstalled = tartInstalled
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
            let preparedNames = await Task.detached { () -> Set<String> in
                // A missing tart binary or a failed listing reads as "image
                // not prepared" — the same state the prepare button offers
                // to fix; failures are logged rather than hidden.
                guard let tart = try? TartController(configuredPath: tartPath) else { return [] }
                do {
                    return Set(try await tart.list().map(\.name))
                } catch {
                    Log.warn("app", "tart list failed while checking '\(image)': \(error.localizedDescription)")
                    return []
                }
            }.value
            let present = preparedNames.contains(image)
            guard let self else { return }
            self.imageLine = Line(
                text: present ? "\(image) ready ✓" : "\(image) not prepared yet — takes a while, once",
                style: present ? .secondary : .warn)
            self.imagePresent = present
            self.namedImages.rows = extra.map {
                .init(
                    name: $0.name, baseImage: $0.baseImage, labels: $0.labels ?? [],
                    present: preparedNames.contains($0.name))
            }
            // Offered even when the image exists: after picking another base image
            // (say an Xcode one) the image must be rebuilt for it to take effect.
            self.imageButtonVisible = true
            self.setTartReady(present)
        }
    }

    private func noteAutoEnabled(_ name: String) {
        installs.busyLine = Line(
            text: "tart isn't installed, so \(name) is on for Linux jobs. Change it below any time.")
    }

    private func setTartReady(_ ready: Bool) {
        readiness.tartReady = ready
        recomputeReadiness()
    }

    /// Re-derives readiness from tart + the Linux toggles. Toggling a runtime
    /// on or off changes it immediately (no reload needed).
    private func recomputeReadiness() {
        readiness.containerEnabled = containerOn
        readiness.containerInstalled = Paths.findExecutable(named: "container") != nil
        readiness.dockerEnabled = dockerOn
        readiness.dockerInstalled = Paths.findExecutable(named: "docker") != nil
        let ready = readiness.isReady
        let changed = ready != isReady
        isReady = ready
        if changed { onReadinessChanged?() }
    }

    /// Reads the config for a passive refresh; a broken file is said on the
    /// status line and reads as nothing saved, never as silent defaults.
    func currentSnapshot() -> GeneralConfigEditor.Snapshot? {
        do {
            return try ConfigStore.snapshot(at: configURL)
        } catch {
            installs.busyLine = .unreadableConfig(error)
            return nil
        }
    }

    // MARK: - Actions

    private static func installLine(installed: Bool, blocked: String?) -> Line {
        if installed { return Line(text: "installed ✓") }
        if let blocked { return Line(text: "not supported — \(blocked)", style: .warn) }
        return Line(text: "not installed")
    }

    /// The tart row's status text. A configured `tart_path:` the probe cannot
    /// find names itself: a bare "not installed" reads like a missing brew
    /// install, which is not what a misconfigured override needs — the path
    /// in config.yaml is the thing to fix (installing elsewhere won't help).
    private static func tartStatus(installed: Bool, configuredPath: String?) -> String {
        if installed { return "installed ✓" }
        guard let configuredPath, !configuredPath.isEmpty else { return "not installed" }
        return "not installed — tart_path: \(configuredPath) does not exist"
    }

    func installTart() { installs.install(.tart) }

    func installContainer() {
        if containerServiceNeedsStart { startContainerService() } else { installs.install(.appleContainer) }
    }

    func installDocker() { installs.install(.docker) }

    /// Presents the Linux-runtime choice sheet from the form's "Set up Linux jobs…" button.
    func chooseLinuxRuntime() { installs.chooseLinuxRuntime() }

    private func checkContainerService() {
        let shell = seams.installShell
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
    func startContainerService() -> Task<Void, Never> { installs.startContainerService() }

    func prepareImage() {
        if imagePresent,
            !seams.confirmRebuild(
                "Rebuild the runner image?",
                "This replaces the existing image with a fresh bake from the selected base image and "
                    + "takes a while. Running VMs keep working; new ones use the rebuilt image.")
        {
            return
        }
        let task = installs.run(
            "Preparing the runner image — this takes a while…",
            cancelledLine: "Cancelled — the previous image is untouched"
        ) {
            try await ImageBuildService.rebuild(.tart, config: ConfigLoader.load())
        }
        isPreparingImage = true
        Task { [weak self] in
            await task.value
            self?.isPreparingImage = false
        }
    }

    /// Builds (or rebuilds) the Linux image for Apple container or Docker from its
    /// configured base image.
    func buildLinuxImage(_ runtime: RuntimeID) {
        guard runtime == .appleContainer || runtime == .docker else { return }
        installs.run(
            "Building the \(runtime == .docker ? "Docker" : "Apple container") image — this takes a while…",
            cancelledLine: "Cancelled — the previous image is untouched"
        ) {
            try await ImageBuildService.rebuild(runtime, config: ConfigLoader.load())
        }
    }

    func setContainer(_ on: Bool) {
        let snap = currentSnapshot()
        containerOn = on
        write(
            .container(on ? (snap?.container ?? .init(image: "kinhin-ci-linux", cpus: 4, memoryGB: 8)) : nil),
            revert: { $0.containerOn = !on })
    }

    func setDocker(_ on: Bool) {
        let snap = currentSnapshot()
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
            installs.busyLine = .notSaved(error)
        }
    }

    // MARK: - Test hooks

    func setTartReadyForTesting(_ ready: Bool) { setTartReady(ready) }
    func setPreparingImageForTesting(_ preparing: Bool) { isPreparingImage = preparing }
    func setImagePresentForTesting(_ present: Bool) { imagePresent = present }
    func setContainerForTesting(_ on: Bool) { setContainer(on) }
    func setDockerForTesting(_ on: Bool) { setDocker(on) }
    func setTartInstalledForTesting(_ installed: Bool) { tartInstalled = installed }
}
