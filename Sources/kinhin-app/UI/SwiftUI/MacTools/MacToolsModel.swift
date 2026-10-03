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

    // MARK: - Display state

    private(set) var tartLine = Line(text: "Checking…")
    private(set) var tartInstallVisible = false
    /// tart is installed on this Mac (the Linux row's checkbox needs it).
    private(set) var tartInstalled = false
    private(set) var imageLine = Line(text: "")
    private(set) var imageButtonVisible = false
    /// The prepared tart image exists, so the button rebuilds it (a changed
    /// base image only takes effect through a rebuild).
    private(set) var imagePresent = false
    /// Extra named macOS images (`images:`), with whether each is prepared.
    struct ImageRow: Identifiable, Equatable {
        var name: String
        var baseImage: String?
        var labels: [String] = []
        var present: Bool
        var id: String { name }
    }
    private(set) var extraImages: [ImageRow] = []
    var imageButtonTitle: String { imagePresent ? "Rebuild image…" : "Prepare image" }
    /// A long-running action (install, prepare image) is in flight.
    private(set) var busy = false
    private(set) var busyLine = Line(text: "")
    /// The task behind the current `busy` action, so the Cancel button can
    /// stop it (an image build then unwinds through its scratch-VM cleanup
    /// and keeps the previous image).
    @ObservationIgnored private(set) var runningTask: Task<Void, Never>?

    /// The open install-confirmation sheet's inputs: what will run and the
    /// methods to choose from. `MacToolsView` presents the sheet while
    /// non-nil (see MacToolsModel+InstallSheets for the sheet's actions).
    var installOffer: InstallOffer?
    /// The open missing-Homebrew sheet's inputs, or nil.
    var missingBrewOffer: MissingBrewOffer?

    private(set) var containerOn = false
    private(set) var dockerOn = false
    private(set) var containerLine = Line(text: "")
    private(set) var dockerLine = Line(text: "")
    private(set) var containerInstallVisible = false
    private(set) var dockerInstallVisible = false
    private(set) var containerInstallTitle = "Install…"
    /// Base image each runtime's image is baked on (nil = default); the
    /// tart value is what `image prepare` starts from.
    private(set) var tartBaseImage: String?
    /// The fleet's `labels:` as saved (what runners advertise to the forge).
    private(set) var fleetLabels: [String] = []
    private(set) var containerBaseImage: String?
    private(set) var dockerBaseImage: String?
    private(set) var dockerPlatform: LinuxPlatform = .arm64

    /// Installed but its background service isn't running: offer to start it
    /// (a fresh install leaves it stopped).
    private var containerServiceNeedsStart = false

    // MARK: - Injectable seams

    @ObservationIgnored var installShell: ShellRunning = Shell()
    /// Whether a tool is installed afterwards (real PATH lookup by default).
    @ObservationIgnored var installedCheck: @Sendable (InstallableTool) -> Bool = { $0.isInstalled }
    @ObservationIgnored var brewPath: () -> String? = { RuntimeInstaller.brewPath }
    /// The Mac install options are judged against (real probe by default).
    @ObservationIgnored var hostFacts: () -> HostFacts = { .current() }
    /// Confirms replacing an existing image (real alert by default; tests inject a closure).
    @ObservationIgnored var confirmRebuild: (_ title: String, _ message: String) -> Bool = { title, message in
        AlertKit.confirm(title: title, message: message, confirmTitle: "Rebuild", destructive: true)
    }
    /// Shown instead of the confirmation when no option can run on this Mac.
    @ObservationIgnored var explainUnsupported: (InstallableTool, Error) -> Void = { tool, error in
        AlertKit.present(error: error, title: "\(tool.title) can't run on this Mac")
    }

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
            busyLine = .unreadableConfig(error)
        }
        containerOn = snapshot?.container != nil
        dockerOn = snapshot?.docker != nil
        refreshBaseImages(from: snapshot)
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
        let extra = snapshot?.images ?? []
        extraImages = extra.map {
            ImageRow(name: $0.name, baseImage: $0.baseImage, labels: $0.labels ?? [], present: false)
        }
        let tartInstalled = TartController.isInstalled()
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
            text: tartInstalled ? "installed ✓" : "not installed", style: tartInstalled ? .secondary : .warn)
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
                guard let tart = try? TartController() else { return [] }
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
            self.extraImages = extra.map {
                ImageRow(
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

    /// Reads the config for a passive refresh; a broken file is said on the
    /// status line and reads as nothing saved, never as silent defaults.
    private func currentSnapshot() -> GeneralConfigEditor.Snapshot? {
        do {
            return try ConfigStore.snapshot(at: configURL)
        } catch {
            busyLine = .unreadableConfig(error)
            return nil
        }
    }

    /// Re-reads the saved base image for each runtime.
    private func refreshBaseImages() {
        refreshBaseImages(from: currentSnapshot())
    }

    private func refreshBaseImages(from snapshot: GeneralConfigEditor.Snapshot?) {
        tartBaseImage = snapshot?.baseImage(for: .tart)
        fleetLabels = snapshot?.labels ?? []
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
            busyLine = .notSaved(error)
            refreshBaseImages()
        }
    }

    /// Tart serves Linux jobs when its base image is a Linux one.
    var tartLinuxOn: Bool { TartBaseImage.isLinux(tartBaseImage) }

    /// Set while tart serves Linux but the fleet still advertises `macos`:
    /// macOS jobs would be routed to a Linux VM and fail there.
    var tartLinuxLabelWarning: String? {
        guard tartLinuxOn, fleetLabels.contains(where: { $0.lowercased() == "macos" }) else { return nil }
        return "Your fleet labels include “macos”, so macOS jobs would be sent to this Linux VM. In config.yaml, "
            + "remove “macos” from labels (add “linux” if jobs ask for it)."
    }

    /// The "Tart (Linux VM)" checkbox: on starts from the default Linux
    /// image; off drops the key, returning tart to the macOS default.
    func setTartLinux(_ on: Bool) {
        guard tartInstalled || !on else { return }
        saveBaseImage(on ? TartBaseImage.defaultLinuxReference : nil, for: .tart)
    }

    func saveBaseImage(_ value: String?, for runtime: RuntimeID) {
        do {
            try GeneralConfigEditor.setBaseImage(value, for: runtime, at: configURL)
            refreshBaseImages()
            onChanged?()
            busyLine = Line(text: "Base image saved. Rebuild the image for it to take effect.")
        } catch {
            busyLine = .notSaved(error)
            refreshBaseImages()
        }
    }

    // MARK: - Actions

    /// Runs a long action with the busy spinner/line managed around it
    /// (internal: the install-sheet extension starts installs through it).
    /// `cancelledLine` is shown when the action is cancelled (default fits
    /// installs; image builds pass their own reassurance). The task is kept
    /// in `runningTask` so `cancelRunning()` can stop it.
    @discardableResult
    func run(
        _ title: String, cancelledLine: String = "Cancelled",
        _ body: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, Never> {
        busy = true
        busyLine = Line(text: title)
        let task = Task { [weak self] in
            do {
                try await body()
                self?.busyLine = Line(text: "")
            } catch is CancellationError {
                self?.busyLine = Line(text: cancelledLine, style: .warn)
            } catch {
                self?.busyLine = Line(text: "Failed — \(error.localizedDescription)", style: .error)
            }
            self?.busy = false
            self?.runningTask = nil
            self?.reload()
        }
        runningTask = task
        return task
    }

    /// The Cancel button's action: cancels the in-flight action. Cancellation
    /// is cooperative — image builds remove their scratch VM and keep the
    /// previous image; child processes are killed by `Shell`.
    func cancelRunning() {
        runningTask?.cancel()
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
            try await AppleContainerRuntime.startSystem(shell: shell)
        }
    }

    /// Install… pressed: confirm in a sheet before anything runs — or, when
    /// no option can run (no Homebrew), explain in a sheet instead. The
    /// sheet's actions start the install (MacToolsModel+InstallSheets).
    func install(_ tool: InstallableTool) {
        let host = hostFacts()
        do {
            try HostRequirements.ensureSupported(tool, on: host)
        } catch {
            explainUnsupported(tool, error)
            return
        }
        let options = HostRequirements.offeredOptions(for: tool, on: host)
        guard brewPath() != nil || options.contains(where: { !$0.needsBrew }) else {
            missingBrewOffer = MissingBrewOffer(tool: tool, options: options)
            return
        }
        installOffer = InstallOffer(tool: tool, options: options)
    }

    func prepareImage() {
        if imagePresent,
            !confirmRebuild(
                "Rebuild the runner image?",
                "This replaces the existing image with a fresh bake from the selected base image and "
                    + "takes a while. Running VMs keep working; new ones use the rebuilt image.")
        {
            return
        }
        run(
            "Preparing the runner image — this takes a while…",
            cancelledLine: "Cancelled — the previous image is untouched"
        ) {
            try await ImageBuildService.rebuild(.tart, config: ConfigLoader.load())
        }
    }

    // MARK: - Named images

    /// Adds an `images:` entry (a name and its base, e.g. a Cirrus `-xcode` image).
    func addImage(name: String, baseImage: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        mutateImages { $0.append(.init(name: trimmed, baseImage: baseImage)) }
    }

    func setImageBase(_ baseImage: String?, for name: String) {
        mutateImages { images in
            if let index = images.firstIndex(where: { $0.name == name }) { images[index].baseImage = baseImage }
        }
        busyLine = Line(text: "Base image saved. Rebuild '\(name)' for it to take effect.")
    }

    /// Sets the labels a job requests (`runs-on`) to run on this image; empty = not selectable by label.
    func setImageLabels(_ text: String, for name: String) {
        let labels = text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        // Focus loss commits too: skip the config write (and engine restart) when nothing changed.
        guard extraImages.first(where: { $0.name == name })?.labels != labels else { return }
        mutateImages { images in
            if let index = images.firstIndex(where: { $0.name == name }) {
                images[index].labels = labels.isEmpty ? nil : labels
            }
        }
    }

    /// Removes the entry from the config. The prepared VM (large) stays on disk; say so.
    func removeImage(_ name: String) {
        mutateImages { $0.removeAll { $0.name == name } }
        busyLine = Line(
            text: "Removed '\(name)' from the config. Its prepared VM is still on disk (tart delete \(name)).")
    }

    func prepareNamedImage(_ name: String) {
        let present = extraImages.first(where: { $0.name == name })?.present ?? false
        if present,
            !confirmRebuild(
                "Rebuild image “\(name)”?",
                "This replaces the existing image with a fresh bake from its base image and takes a while.")
        {
            return
        }
        run(
            "Preparing image “\(name)” — this takes a while…",
            cancelledLine: "Cancelled — the previous image is untouched"
        ) {
            try await ImageBuildService.rebuild(.tart, config: ConfigLoader.load(), image: name)
        }
    }

    private func mutateImages(_ change: (inout [KinhinConfig.ImageConfig]) -> Void) {
        do {
            var images = try ConfigStore.snapshot(at: configURL)?.images ?? []
            change(&images)
            try ImagesConfigEditor.apply(images, to: configURL)
            reload()
            onChanged?()
        } catch {
            busyLine = .notSaved(error)
        }
    }

    /// Builds (or rebuilds) the Linux image for Apple container or Docker from its
    /// configured base image.
    func buildLinuxImage(_ runtime: RuntimeID) {
        guard runtime == .appleContainer || runtime == .docker else { return }
        run(
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
            busyLine = .notSaved(error)
        }
    }

    /// Appends the by-hand command to a failed install's busy line (internal:
    /// the install-sheet extension calls it from the follow-up task).
    func noteManualCommandFallback(_ command: String) {
        guard busyLine.text.hasPrefix("Failed") else { return }
        busyLine.text += "\nYou can also run this in Terminal: \(command)"
    }

    // MARK: - Test hooks

    func setTartReadyForTesting(_ ready: Bool) { setTartReady(ready) }
    func setImagePresentForTesting(_ present: Bool) { imagePresent = present }
    func setContainerForTesting(_ on: Bool) { setContainer(on) }
    func setDockerForTesting(_ on: Bool) { setDocker(on) }
    func setTartInstalledForTesting(_ installed: Bool) { tartInstalled = installed }
}
