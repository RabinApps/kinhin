import AppKit
import KinhinKit

// The Routing pane's two AppKit modals, invoked from `RuntimesModel`.
// Kept AppKit on purpose: an NSAlert accessory view is the right tool for a
// two-field prompt and a big validated text editor.

@MainActor
enum RuntimesSheets {
    // MARK: Add Route

    static let hostConsentTitle = "Host only: run this repo's code directly on my Mac, unisolated"

    /// The Add Route form with explicit frames (an NSAlert accessory view
    /// doesn't run Auto Layout, so stack views collapse there).
    static func makeRouteForm(runtimes: [RuntimeID]) -> (
        view: NSView, pattern: NSTextField, popup: NSPopUpButton, consent: NSButton
    ) {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 96))
        let pattern = NSTextField(frame: NSRect(x: 0, y: 72, width: 340, height: 24))
        pattern.placeholderString = "acme/api  or  acme/api@Workflow Name"
        pattern.setAccessibilityLabel("Repo or workflow pattern")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 40, width: 340, height: 26), pullsDown: false)
        for id in runtimes {
            switch id {
            case .tart: popup.addItem(withTitle: "tart — macOS VMs")
            case .appleContainer: popup.addItem(withTitle: "Apple container — Linux")
            case .docker: popup.addItem(withTitle: "Docker — Linux")
            case .host: popup.addItem(withTitle: "Host — this Mac, no isolation")
            }
            popup.lastItem?.representedObject = id.rawValue
        }
        popup.setAccessibilityLabel("Runtime to use")
        let consent = NSButton(checkboxWithTitle: hostConsentTitle, target: nil, action: nil)
        consent.frame = NSRect(x: 0, y: 4, width: 340, height: 28)
        consent.font = .systemFont(ofSize: 11)
        consent.setAccessibilityLabel("Host route consent")
        view.addSubview(pattern)
        view.addSubview(popup)
        view.addSubview(consent)
        return (view, pattern, popup, consent)
    }

    /// The Add Route alert with its host-consent loop. Returns the entered
    /// route, or nil when the user cancels or never confirms host consent.
    static func promptForRoute(runtimes: [RuntimeID]) -> (pattern: String, runtime: RuntimeID, consent: Bool)? {
        let alert = NSAlert()
        alert.messageText = "Add Route"
        alert.informativeText =
            "Send a repository, or one workflow, to a runtime. Use owner/repo for a whole repo, or owner/repo@Workflow Name for one workflow."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let form = makeRouteForm(runtimes: runtimes)
        alert.accessoryView = form.view
        alert.window.initialFirstResponder = form.pattern
        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let pattern = form.pattern.stringValue.trimmingCharacters(in: .whitespaces)
            if pattern.isEmpty {
                alert.informativeText = "Enter a repository (owner/repo) first."
                continue
            }
            guard let raw = form.popup.selectedItem?.representedObject as? String, let id = RuntimeID(rawValue: raw)
            else { return nil }
            let consented = form.consent.state == .on
            if id == .host && !consented {
                alert.informativeText =
                    "Host routes run this repo's code directly on your Mac with your privileges. Tick the box to confirm, or pick another runtime."
                continue
            }
            return (pattern, id, id == .host && consented)
        }
    }

    // MARK: Edit YAML

    /// The validated in-UI editor sheet. The textarea starts from the exact
    /// on-disk bytes; Save writes through ConfigEditor, so the engine's full
    /// validation gates the result — a bad edit shows the error instead of
    /// landing on disk.
    static func editConfigYAML(configURL: URL) {
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
        } catch {
            AlertKit.present(error: error, title: "Couldn't update the routing config")
        }
    }
}
