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
        alert.addButton(
            withTitle: String(localized: "OK", bundle: .l10n, comment: "Dismiss button of an informational alert"))
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
        alert.addButton(
            withTitle: String(localized: "Cancel", bundle: .l10n, comment: "Cancel button of a confirmation alert"))
        if destructive { alert.buttons.first?.hasDestructiveAction = true }
        return runModal(alert) == .alertFirstButtonReturn
    }

    /// A scope picker as radio buttons in an alert (reset's first dialog).
    /// Returns the picked scope, or nil when the alert was cancelled.
    static func chooseResetScope(title: String, message: String) -> ResetScope? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(
            withTitle: String(localized: "Continue", bundle: .l10n, comment: "Default button of the reset-scope alert"))
        alert.addButton(
            withTitle: String(localized: "Cancel", bundle: .l10n, comment: "Cancel button of the reset-scope alert"))
        let checkboxes = ResetScope.allCases.map { scope -> NSButton in
            let button = NSButton(checkboxWithTitle: scope.label, target: nil, action: nil)
            button.toolTip = scope.summary
            button.sizeToFit()

            // Optional: Set default state (e.g., checked by default)
            button.state = .off

            return button
        }

        // 2. Instantiate an empty stack view instead of initializing with views
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        for checkbox in checkboxes {
            stack.addArrangedSubview(checkbox)
        }

        // 2. Measure geometry precisely for layout placement
        let width: CGFloat = 300
        let itemHeight: CGFloat = checkboxes.first?.frame.height ?? 18
        let totalSpacing = stack.spacing * CGFloat(checkboxes.count - 1)
        let totalHeight = (itemHeight * CGFloat(checkboxes.count)) + totalSpacing

        stack.setFrameSize(NSSize(width: width, height: totalHeight))
        stack.translatesAutoresizingMaskIntoConstraints = true

        // 6. Assign to the alert
        alert.accessoryView = stack

        alert.layout()
        guard runModal(alert) == .alertFirstButtonReturn else { return nil }
        return zip(checkboxes, ResetScope.allCases).first { $0.0.state == .on }?.1
    }

    /// A confirmation that requires typing `word` exactly (reset's second,
    /// final gate). The confirm button stays disabled until the text matches,
    /// so the only way through is deliberate typing; anything else cancels.
    static func confirmWithTypedWord(title: String, message: String, word: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(
            withTitle: String(
                localized: "Cancel", bundle: .l10n, comment: "Cancel button of the typed-word confirmation alert"))
        let confirm = alert.buttons[0]
        confirm.hasDestructiveAction = true
        confirm.isEnabled = false
        let field = NSTextField()
        field.placeholderString = String(
            localized: "type \(word)", bundle: .l10n,
            comment: "Placeholder in the typed-confirmation alert; %@ is the word to type, which stays verbatim")
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        alert.accessoryView = field
        // The gate: the button enables only on an exact match. Kept alive for
        // the whole modal run by this local.
        let gate = TypedWordGate(field: field, button: confirm, word: word)
        field.delegate = gate
        _ = gate
        return runModal(alert) == .alertFirstButtonReturn && field.stringValue == word
    }

    /// Enables the typed-word alert's confirm button only when the field
    /// matches the required word exactly.
    private final class TypedWordGate: NSObject, NSTextFieldDelegate {
        private let field: NSTextField
        private let button: NSButton
        private let word: String

        init(field: NSTextField, button: NSButton, word: String) {
            self.field = field
            self.button = button
            self.word = word
        }

        func controlTextDidChange(_ obj: Notification) {
            button.isEnabled = field.stringValue == word
        }
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
