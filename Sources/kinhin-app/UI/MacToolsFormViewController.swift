import AppKit
import KinhinKit
import SwiftUI

/// "This Mac": what kinhin runs jobs on, with real actions instead of
/// instructions. macOS jobs need tart and a prepared base image (both can be
/// fixed here); Linux jobs can optionally use Apple container or Docker
/// (toggling writes the config section with sensible defaults).
///
/// Shared by the onboarding wizard and the Setup tab. A thin AppKit host:
/// state and actions live in `MacToolsModel`, the UI in `MacToolsView`.
@MainActor
final class MacToolsFormViewController: NSViewController {
    let model = MacToolsModel()

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("created in code") }

    override func loadView() {
        view = NSHostingView(rootView: MacToolsView(model: model))
        reload()
    }

    // MARK: Forwarding (the wizard, Accounts page, and tests use these)

    /// The config file this form edits (tests point it at a scratch file).
    var configURL: URL {
        get { model.configURL }
        set { model.configURL = newValue }
    }
    var onChanged: (() -> Void)? {
        get { model.onChanged }
        set { model.onChanged = newValue }
    }
    var onReadinessChanged: (() -> Void)? {
        get { model.onReadinessChanged }
        set { model.onReadinessChanged = newValue }
    }
    /// True when the fleet has something to run jobs on (see `MacToolsModel`).
    var isReady: Bool { model.isReady }
    var autoEnableLinuxRuntime: Bool {
        get { model.autoEnableLinuxRuntime }
        set { model.autoEnableLinuxRuntime = newValue }
    }
    var activeLinuxRuntimes: [String] { model.activeLinuxRuntimes }
    /// Plain-language summary of what jobs can run here (for the final step).
    var runsOnDescription: String { model.runsOnDescription }

    var confirmInstall: (InstallableTool, [InstallOption]) -> InstallOption? {
        get { model.confirmInstall }
        set { model.confirmInstall = newValue }
    }
    var explainMissingBrew: (InstallableTool, [InstallOption]) -> Void {
        get { model.explainMissingBrew }
        set { model.explainMissingBrew = newValue }
    }
    var installShell: ShellRunning {
        get { model.installShell }
        set { model.installShell = newValue }
    }
    var installedCheck: @Sendable (InstallableTool) -> Bool {
        get { model.installedCheck }
        set { model.installedCheck = newValue }
    }
    var brewPath: () -> String? {
        get { model.brewPath }
        set { model.brewPath = newValue }
    }

    func reload() { model.reload() }

    @discardableResult
    func install(_ tool: InstallableTool) -> Task<Void, Never>? { model.install(tool) }

    @discardableResult
    func startContainerService() -> Task<Void, Never> { model.startContainerService() }

    // MARK: Test hooks

    func setTartReadyForTesting(_ ready: Bool) { model.setTartReadyForTesting(ready) }
    func setContainerForTesting(_ on: Bool) { model.setContainerForTesting(on) }
    func setDockerForTesting(_ on: Bool) { model.setDockerForTesting(on) }
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
