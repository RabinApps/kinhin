import AppKit
import KinhinKit

/// The Runtimes pane: read-only view of the fleet's runtime pools, capacity
/// partition, and per-repo/per-workflow routes — with light editing (add and
/// remove routes, via the validated config editor). Heavier editing opens
/// the YAML; every write goes through RuntimesConfigEditor so the rest of
/// the config file is preserved and engine validation gates the result.
@MainActor
final class RuntimesWindowController: NSWindowController {
    var onEdited: (() -> Void)?
    /// The config file this pane reads and edits (tests point it at a scratch file).
    var configURL: URL = Paths.config

    let rowsStack = NSStackView()
    let headlineLabel = NSTextField(labelWithString: "")
    var viewModel: RuntimesPaneViewModel?
    var previewCommitTask: Task<Void, Never>?
    var parsedConfigForPreview: KinhinConfig?
    var currentRuntimeConfig: KinhinConfig.RuntimeConfig?

    /// Test hooks.
    var reloadCount = 0

    /// Overridable so tests never open a modal: returns (pattern, runtime) or nil.
    var promptForRoute: ([RuntimeID]) -> (String, RuntimeID)? = { runtimes in
        let alert = NSAlert()
        alert.messageText = "Add Route"
        alert.informativeText =
            "Send a repository, or one workflow, to a runtime. Use owner/repo for a whole repo, or owner/repo@Workflow Name for one workflow."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let form = RuntimesWindowController.makeRouteForm(runtimes: runtimes)
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
            return (pattern, id)
        }
    }

    /// Where routing problems and "nothing to do" explanations are shown.
    var presentNotice: (_ title: String, _ message: String) -> Void = { title, message in
        AlertKit.notice(title, message)
    }

    convenience init() {
        self.init(embeddedIn: nil)
    }

    /// Embedded in the main window's Runtimes tab: `container` receives the
    /// full pane. Nil container → the standalone-window form, unchanged.
    convenience init(embeddedIn container: NSView?) {
        let size = NSSize(width: 560, height: 520)
        let standalone = container == nil
        let contentContainer = container ?? NSView(frame: NSRect(origin: .zero, size: size))
        if standalone {
            let window = NSWindow(
                contentRect: contentContainer.frame,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "kinhin Runtimes"
            window.titlebarAppearsTransparent = true
            window.appearance = nil  // follow the system (light & dark)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = contentContainer
            window.center()
            self.init(window: window)
        } else {
            self.init(window: nil)
        }
        buildUI(in: contentContainer, size: size)
    }

    // MARK: UI construction

    func buildUI(in container: NSView, size: NSSize) {
        container.wantsLayer = true

        // ---- Header -----------------------------------------------------
        let title = NSTextField(labelWithString: "⚖️  Runtimes")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        headlineLabel.font = .systemFont(ofSize: 13)
        headlineLabel.textColor = .secondaryLabelColor
        headlineLabel.maximumNumberOfLines = 2

        let headerStack = NSStackView(views: [title, headlineLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerStack)

        // ---- Scrollable content ------------------------------------------
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 8
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        // Flipped document so the page opens at the TOP (an unflipped one
        // starts scrolled to the bottom and clips the first cards).
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowsStack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        // ---- Footer -------------------------------------------------------
        let addRouteButton = NSButton(title: "Add Route…", target: self, action: #selector(addRouteClicked))
        addRouteButton.bezelStyle = .rounded
        let editButton = NSButton(title: "Edit YAML…", target: self, action: #selector(editConfigInUI))
        editButton.bezelStyle = .rounded
        let hint = NSTextField(labelWithString: "Slider changes apply on release; validation gates every write.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let footer = NSStackView(views: [addRouteButton, editButton, hint])
        footer.orientation = .horizontal
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            headerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            headerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
    }
}
