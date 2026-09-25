import AppKit
import KinhinKit

/// "This Mac": what kinhin runs jobs on, with real actions instead of
/// instructions. macOS jobs need tart and a prepared base image (both can be
/// fixed here); Linux jobs can optionally use Apple container or Docker
/// (toggling writes the config section with sensible defaults).
///
/// Shared by the onboarding wizard and the Setup tab.
@MainActor
final class MacToolsFormViewController: NSViewController {
    /// The config file this form edits (tests point it at a scratch file).
    var configURL: URL = Paths.config
    var onChanged: (() -> Void)?

    /// True when the fleet has something to run jobs on: tart with its base
    /// image, or an enabled Linux runtime (Docker / Apple container) that is
    /// actually installed. Tart is optional — a Linux-only Mac is a valid setup.
    private(set) var isReady = false
    var onReadinessChanged: (() -> Void)?

    /// The wizard sets this: when tart isn't installed and no Linux runtime is
    /// on, switch on an installed Docker / Apple container so setup can
    /// finish, and say so. (The Accounts page leaves choices alone.)
    var autoEnableLinuxRuntime = false

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

    private let tartStatus = NSTextField(labelWithString: "Checking…")
    private let tartButton = NSButton(title: "Install…", target: nil, action: nil)
    private let imageStatus = NSTextField(labelWithString: "")
    private let imageButton = NSButton(title: "Prepare image", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let busyLabel = NSTextField(labelWithString: "")

    private let containerToggle = NSButton(checkboxWithTitle: "Apple container", target: nil, action: nil)
    private let containerStatus = NSTextField(labelWithString: "")
    private let dockerToggle = NSButton(checkboxWithTitle: "Docker", target: nil, action: nil)
    private let dockerStatus = NSTextField(labelWithString: "")
    /// Base image each Linux runtime's image is baked on (shown while it's enabled).
    let containerBasePicker = BaseImagePicker(value: nil)
    let dockerBasePicker = BaseImagePicker(value: nil)
    private var containerBaseRow: NSView?
    private var dockerBaseRow: NSView?
    private let containerInstallButton = NSButton(title: "Install…", target: nil, action: nil)
    private let dockerInstallButton = NSButton(title: "Install…", target: nil, action: nil)

    /// Asks the user to confirm an install and pick a method. Returns the
    /// chosen option, or nil when cancelled. Injectable so tests never open a
    /// modal alert or run Homebrew.
    var confirmInstall: (InstallableTool, [InstallOption]) -> InstallOption? = { tool, options in
        MacToolsFormViewController.presentInstallConfirmation(tool: tool, options: options)
    }
    /// Shown instead of the confirmation when Homebrew is missing.
    var explainMissingBrew: (InstallableTool, [InstallOption]) -> Void = { tool, options in
        MacToolsFormViewController.presentMissingBrew(tool: tool, options: options)
    }
    var installShell: ShellRunning = Shell()
    /// Whether a tool is installed afterwards (real PATH lookup by default).
    var installedCheck: @Sendable (InstallableTool) -> Bool = { $0.isInstalled }
    var brewPath: () -> String? = { RuntimeInstaller.brewPath }

    private let stack = NSStackView()

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("created in code") }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(buildMacCard())
        stack.addArrangedSubview(buildLinuxCard())

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        view = container
        reload()
    }

    // MARK: Construction

    private func buildMacCard() -> NSView {
        let (card, column) = FormKit.card(
            title: "macOS jobs (optional)",
            subtitle:
                "Run macOS workflows in disposable virtual machines powered by tart. Skip this if you only need Linux jobs."
        )
        for status in [tartStatus, imageStatus, busyLabel] {
            status.font = .systemFont(ofSize: 11)
            status.textColor = .secondaryLabelColor
        }
        tartButton.bezelStyle = .rounded
        tartButton.controlSize = .small
        tartButton.target = self
        tartButton.action = #selector(installTart)
        tartButton.identifier = NSUserInterfaceItemIdentifier("mac-install-tart")
        imageButton.bezelStyle = .rounded
        imageButton.controlSize = .small
        imageButton.target = self
        imageButton.action = #selector(prepareImage)
        imageButton.identifier = NSUserInterfaceItemIdentifier("mac-prepare-image")
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        column.addArrangedSubview(
            FormKit.row([FormKit.label("tart", weight: .semibold), tartStatus, FormKit.spacer(), tartButton]))
        column.addArrangedSubview(
            FormKit.row([FormKit.label("Base image", weight: .semibold), imageStatus, FormKit.spacer(), imageButton]))
        column.addArrangedSubview(FormKit.row([progress, busyLabel]))
        return card
    }

    private func buildLinuxCard() -> NSView {
        let (card, column) = FormKit.card(
            title: "Linux jobs (optional)",
            subtitle: "Turn one on to run Linux workflows. Without tart, this is all you need."
        )
        containerToggle.target = self
        containerToggle.action = #selector(containerToggled)
        containerToggle.identifier = NSUserInterfaceItemIdentifier("mac-container-toggle")
        dockerToggle.target = self
        dockerToggle.action = #selector(dockerToggled)
        dockerToggle.identifier = NSUserInterfaceItemIdentifier("mac-docker-toggle")
        for status in [containerStatus, dockerStatus] {
            status.font = .systemFont(ofSize: 11)
            status.textColor = .secondaryLabelColor
        }
        for (button, action, id) in [
            (containerInstallButton, #selector(installContainer), "mac-install-container"),
            (dockerInstallButton, #selector(installDocker), "mac-install-docker"),
        ] as [(NSButton, Selector, String)] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.isHidden = true
        }
        column.addArrangedSubview(
            FormKit.row([containerToggle, containerStatus, FormKit.spacer(), containerInstallButton]))
        containerBaseRow = baseImageRow(containerBasePicker, runtime: .appleContainer, in: column)
        column.addArrangedSubview(FormKit.row([dockerToggle, dockerStatus, FormKit.spacer(), dockerInstallButton]))
        dockerBaseRow = baseImageRow(dockerBasePicker, runtime: .docker, in: column)
        return card
    }

    /// "Base image" row under a runtime's toggle; hidden until it is enabled.
    private func baseImageRow(_ picker: BaseImagePicker, runtime: RuntimeID, in column: NSStackView) -> NSView {
        picker.onChange = { [weak self] value in self?.saveBaseImage(value, for: runtime) }
        let row = FormKit.row([FormKit.label("Base image"), FormKit.spacer(), picker])
        row.isHidden = true
        column.addArrangedSubview(row)
        return row
    }

    private func saveBaseImage(_ value: String?, for runtime: RuntimeID) {
        do {
            try GeneralConfigEditor.setBaseImage(value, for: runtime, at: configURL)
            onChanged?()
        } catch {
            busyLabel.stringValue = "Not saved — \(error.localizedDescription)"
            busyLabel.textColor = .systemRed
            refreshBaseImagePickers()
        }
    }

    /// Shows each picker while its runtime is enabled, with the saved value.
    private func refreshBaseImagePickers() {
        let snapshot = ConfigStore.snapshotOrLog(at: configURL)
        containerBasePicker.setValue(snapshot?.baseImage(for: .appleContainer))
        dockerBasePicker.setValue(snapshot?.baseImage(for: .docker))
        containerBaseRow?.isHidden = containerToggle.state != .on
        dockerBaseRow?.isHidden = dockerToggle.state != .on
    }

    // MARK: State

    func reload() {
        let snapshot = ConfigStore.snapshotOrLog(at: configURL)
        containerToggle.state = snapshot?.container != nil ? .on : .off
        dockerToggle.state = snapshot?.docker != nil ? .on : .off
        refreshBaseImagePickers()
        let containerInstalled = Paths.findExecutable(named: "container") != nil
        let dockerInstalled = Paths.findExecutable(named: "docker") != nil
        recomputeReadiness()
        containerInstallButton.isHidden = containerInstalled
        containerInstallButton.title = "Install…"
        containerServiceNeedsStart = false
        dockerInstallButton.isHidden = dockerInstalled
        containerStatus.stringValue = containerInstalled ? "installed ✓" : "not installed"
        dockerStatus.stringValue = dockerInstalled ? "installed ✓" : "not installed"

        let image = snapshot?.image ?? "tahoe-base"
        let tartInstalled = TartController.isInstalled()
        if autoEnableLinuxRuntime, !tartInstalled, containerToggle.state == .off, dockerToggle.state == .off {
            if dockerInstalled {
                dockerToggle.state = .on
                dockerToggled()
                noteAutoEnabled("Docker")
            } else if containerInstalled {
                containerToggle.state = .on
                containerToggled()
                noteAutoEnabled("Apple container")
            }
        }
        tartStatus.stringValue = tartInstalled ? "installed ✓" : "not installed"
        tartStatus.textColor = tartInstalled ? .secondaryLabelColor : .systemOrange
        tartButton.isHidden = tartInstalled
        if containerInstalled { checkContainerService() }
        guard tartInstalled else {
            imageStatus.stringValue = "needs tart first"
            imageButton.isHidden = true
            setTartReady(false)
            return
        }
        imageStatus.stringValue = "checking \(image)…"
        imageButton.isHidden = true
        Task { [weak self] in
            let present = await Task.detached { () -> Bool in
                guard let tart = try? TartController() else { return false }
                return ((try? await tart.list()) ?? []).contains { $0.name == image }
            }.value
            guard let self else { return }
            self.imageStatus.stringValue =
                present ? "\(image) ready ✓" : "\(image) not prepared yet — takes a while, once"
            self.imageStatus.textColor = present ? .secondaryLabelColor : .systemOrange
            self.imageButton.isHidden = present
            self.setTartReady(present)
        }
    }

    private func noteAutoEnabled(_ name: String) {
        busyLabel.stringValue = "tart isn't installed, so \(name) is on for Linux jobs. Change it below any time."
        busyLabel.textColor = .secondaryLabelColor
    }

    private func setTartReady(_ ready: Bool) {
        tartReady = ready
        recomputeReadiness()
    }

    /// Re-derives readiness from tart + the Linux toggles. Toggling a runtime
    /// on or off changes it immediately (no reload needed).
    private func recomputeReadiness() {
        var active: [String] = []
        if containerToggle.state == .on, Paths.findExecutable(named: "container") != nil {
            active.append("Apple container")
        }
        if dockerToggle.state == .on, Paths.findExecutable(named: "docker") != nil { active.append("Docker") }
        activeLinuxRuntimes = active
        let ready = tartReady || !active.isEmpty
        let changed = ready != isReady
        isReady = ready
        if changed { onReadinessChanged?() }
    }

    // MARK: Actions

    @discardableResult
    private func run(_ title: String, _ body: @escaping @Sendable () async throws -> Void) -> Task<Void, Never> {
        let buttons = [tartButton, imageButton, containerInstallButton, dockerInstallButton]
        buttons.forEach { $0.isEnabled = false }
        busyLabel.stringValue = title
        busyLabel.textColor = .secondaryLabelColor
        progress.startAnimation(nil)
        return Task { [weak self] in
            do {
                try await body()
                self?.busyLabel.stringValue = ""
            } catch {
                self?.busyLabel.stringValue = "Failed — \(error.localizedDescription)"
                self?.busyLabel.textColor = .systemRed
            }
            self?.progress.stopAnimation(nil)
            buttons.forEach { $0.isEnabled = true }
            self?.reload()
        }
    }

    @objc private func installTart() { install(.tart) }
    @objc private func installContainer() {
        if containerServiceNeedsStart { startContainerService() } else { install(.appleContainer) }
    }

    /// Installed but its background service isn't running: offer to start it
    /// (a fresh install leaves it stopped).
    private var containerServiceNeedsStart = false

    private func checkContainerService() {
        let shell = installShell
        Task { [weak self] in
            let ready = await Task.detached { await AppleContainerRuntime(shell: shell).health().isReady }.value
            guard let self, !ready, self.containerStatus.stringValue.hasPrefix("installed") else { return }
            self.containerServiceNeedsStart = true
            self.containerStatus.stringValue = "installed, but its service isn't running"
            self.containerStatus.textColor = .systemOrange
            self.containerInstallButton.title = "Start service"
            self.containerInstallButton.isHidden = false
        }
    }

    @discardableResult
    func startContainerService() -> Task<Void, Never> {
        let shell = installShell
        return run("Starting the Apple container service…") {
            try await SetupWindowController.startContainerSystem(shell: shell)
        }
    }
    @objc private func installDocker() { install(.docker) }

    /// Confirm → install → re-check. Nothing runs without an explicit yes, and
    /// a missing Homebrew gets an explanation instead of a failing command.
    @discardableResult
    func install(_ tool: InstallableTool) -> Task<Void, Never>? {
        let options = RuntimeInstaller.options(for: tool)
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
            try await RuntimeInstaller.install(choice, tool: tool, shell: shell, brew: brew, isInstalled: installed)
        }
        // On failure, tell the user how to do it by hand.
        Task { [weak self] in
            await task.value
            guard let self, self.busyLabel.stringValue.hasPrefix("Failed") else { return }
            self.busyLabel.stringValue += "\nYou can also run this in Terminal: \(choice.commandLine)"
        }
        return task
    }

    @objc private func prepareImage() {
        run("Preparing the runner image — this takes a while, but only once…") {
            let cfg = try ConfigLoader.load()
            let tart = try TartController(configuredPath: cfg.tartPath)
            var options = ImagePreparer.Options()
            options.provisionScriptPath = cfg.provisionScript
            options.toolchains = cfg.toolchains
            try await ImagePreparer(tart: tart, ssh: SSHExecutor()).run(options)
        }
    }

    @objc private func containerToggled() {
        let snap = ConfigStore.snapshotOrLog(at: configURL)
        write(
            .container(
                containerToggle.state == .on
                    ? (snap?.container ?? .init(image: "kinhin-ci-linux", cpus: 4, memoryGB: 8)) : nil),
            revert: containerToggle)
    }

    @objc private func dockerToggled() {
        let snap = ConfigStore.snapshotOrLog(at: configURL)
        write(
            .docker(
                dockerToggle.state == .on
                    ? (snap?.docker ?? .init(image: "kinhin-ci-linux", cpus: 2, memoryGB: 4, maxSlots: 8)) : nil),
            revert: dockerToggle)
    }

    private func write(_ field: GeneralConfigEditor.Field, revert toggle: NSButton) {
        do {
            try GeneralConfigEditor.apply(field, to: configURL)
            recomputeReadiness()
            refreshBaseImagePickers()
            onChanged?()
        } catch {
            toggle.state = toggle.state == .on ? .off : .on
            recomputeReadiness()
            busyLabel.stringValue = "Not saved — \(error.localizedDescription)"
            busyLabel.textColor = .systemRed
        }
    }

    // MARK: Test hooks

    func setTartReadyForTesting(_ ready: Bool) { setTartReady(ready) }

    func setContainerForTesting(_ on: Bool) { containerToggle.state = on ? .on : .off; containerToggled() }
    func setDockerForTesting(_ on: Bool) { dockerToggle.state = on ? .on : .off; dockerToggled() }
}

// MARK: - Install dialogs

extension MacToolsFormViewController {
    /// "Install X?" — states exactly what will run, lets the user pick a
    /// method when there are several, and offers to copy the command instead.
    static func presentInstallConfirmation(tool: InstallableTool, options: [InstallOption]) -> InstallOption? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Install \(tool.title)?"
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Copy Command")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        options.forEach { popup.addItem(withTitle: $0.title) }
        let detail = NSTextField(wrappingLabelWithString: "")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 300
        let command = NSTextField(wrappingLabelWithString: "")
        command.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        command.isSelectable = true
        command.preferredMaxLayoutWidth = 300

        func refresh() {
            let option = options[max(0, popup.indexOfSelectedItem)]
            detail.stringValue = option.detail
            command.stringValue = option.commandLine
        }
        refresh()
        let handler = PopupHandler(refresh)
        popup.target = handler
        popup.action = #selector(PopupHandler.changed)

        let stack = NSStackView(views: options.count > 1 ? [popup, detail, command] : [detail, command])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: options.count > 1 ? 150 : 110)
        alert.informativeText =
            "kinhin will run this with Homebrew. It may take several minutes, and some installers ask for your password or need a first launch afterwards."
        alert.accessoryView = stack

        let response = alert.runModal()
        _ = handler  // keep alive for the popup's action
        let chosen = options[max(0, popup.indexOfSelectedItem)]
        switch response {
        case .alertFirstButtonReturn:
            return chosen
        case .alertThirdButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(chosen.commandLine, forType: .string)
            return nil
        default:
            return nil
        }
    }

    static func presentMissingBrew(tool: InstallableTool, options: [InstallOption]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Homebrew isn't installed"
        alert.informativeText =
            "kinhin installs \(tool.title) with Homebrew. Install Homebrew first, or download \(tool.title) yourself."
        alert.addButton(withTitle: "Get Homebrew")
        if options.first?.manualURL != nil { alert.addButton(withTitle: "Download \(tool.title)") }
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn, let url = URL(string: "https://brew.sh") {
            NSWorkspace.shared.open(url)
        } else if response == .alertSecondButtonReturn, let url = options.first?.manualURL {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
private final class PopupHandler: NSObject {
    private let onChange: () -> Void
    init(_ onChange: @escaping () -> Void) { self.onChange = onChange }
    @objc func changed() { onChange() }
}
