import AppKit
import KinhinKit

// The in-UI YAML editor sheet.
@MainActor
extension RuntimesWindowController {
    // MARK: Config editing (in-UI YAML editor)

    /// Opens the validated in-UI editor sheet. The textarea starts from the
    /// exact on-disk bytes; Save writes through ConfigEditor, so the engine's
    /// full validation gates the result — a bad edit shows the error instead
    /// of landing on disk.
    @objc func editConfigInUI() {
        // No window guard here: the embedded Runtimes tab has no own window
        // (only the standalone pane does), and runModal works either way.
        let original: String
        do {
            original = try ConfigStore.text(at: configURL)
        } catch {
            AlertKit.present(error: error, title: "Can't open config.yaml")
            return
        }

        let editor = NSTextView()
        editor.string = original
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isEditable = true
        editor.setAccessibilityLabel("config.yaml editor")
        // Track the clip view's width (same as the Logs viewer): an
        // autoresizing text view is sized once and never grows/shrinks when
        // the alert is resized or laid out late.
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        scroll.hasVerticalScroller = true
        scroll.documentView = editor
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(
            labelWithString: "Saved only if the whole file still passes the engine's config validation.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let column = NSStackView(views: [hint, scroll])
        column.orientation = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: 560).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 420).isActive = true

        let alert = NSAlert()
        alert.messageText = "Edit config.yaml"
        alert.alertStyle = .informational
        alert.accessoryView = column
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = editor

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let updated = editor.string
        guard updated != original else { return }
        do {
            try ConfigEditor.save(updated, to: configURL)
            Log.info("runtimes-pane", "config edited in UI; validation passed")
            onEdited?()
        } catch {
            presentError(error)
        }
        reload()
    }
}
