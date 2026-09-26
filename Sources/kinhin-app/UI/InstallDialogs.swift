import AppKit
import KinhinKit
import SwiftUI

// The install dialogs for the This-Mac form, invoked from `MacToolsModel`'s
// injectable seams. Kept AppKit on purpose: an NSAlert accessory view is the
// right tool for a method picker, and the model's seams keep them out of tests.

@MainActor
enum InstallDialogs {
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
