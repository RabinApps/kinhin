import AppKit
import KinhinKit

/// The one place modal alerts are built. Every call funnels through `runModal`,
/// so tests can swap it out and nothing ever blocks on a real dialog.
@MainActor
enum AlertKit {
    /// Presents an alert and returns the button pressed. Tests replace this.
    static var runModal: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }

    /// An informational (or warning/critical) message with a single OK button.
    static func notice(_ title: String, _ message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = runModal(alert)
    }

    /// A two-button confirmation. Returns true when the confirm button is pressed.
    static func confirm(
        title: String,
        message: String,
        confirmTitle: String,
        style: NSAlert.Style = .warning,
        destructive: Bool = false
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        if destructive { alert.buttons.first?.hasDestructiveAction = true }
        return runModal(alert) == .alertFirstButtonReturn
    }

    /// Shows a failed user action: `title` says what was attempted, the
    /// error's own description says why. Also logged, so the reason survives
    /// the dialog being dismissed.
    static func present(error: Error, title: String) {
        let reason = error.localizedDescription
        Log.error("app", "\(title): \(reason)")
        notice(title, reason, style: .warning)
    }
}
