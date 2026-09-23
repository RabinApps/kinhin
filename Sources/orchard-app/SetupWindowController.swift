import AppKit
import OrchardKit

/// Guided first-run setup. Renders SetupViewModel (computed in OrchardKit,
/// unit-tested) as a scrollable card checklist with a progress header and a
/// footer.
@MainActor
final class SetupWindowController: NSWindowController {
    var onFinished: (() -> Void)?
    /// Token checklist rows (enter/replace token, Gitea variants) open the
    /// shared token settings form; the app injects the opener.
    var onOpenTokenSettings: ((ForgeID) -> Void)?

    private let headerStack = NSStackView()
    private let headlineLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let rowsStack = NSStackView()
    private let startButton = NSButton(title: "Start Fleet", target: nil, action: nil)
    var canStart = false

    convenience init() {
        // Size from the shared layout math (fits five cards without scrolling).
        let size = NSSize(width: SetupWindowLayout.windowWidth, height: SetupWindowLayout.windowHeight(forRows: 6))
        let container = NSView(frame: NSRect(origin: .zero, size: size))

        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Orchard Setup"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = container
        window.center()
        self.init(window: window)

        buildUI(in: container, size: size)
        // Synchronous placeholders: never an empty window, even while probing.
        render(viewModel: SetupViewModel(checks: [], isLoading: true))
    }

    // MARK: UI construction

    private func buildUI(in container: NSView, size: NSSize) {
        container.wantsLayer = true

        // ---- Header -----------------------------------------------------
        let title = NSTextField(labelWithString: "🌳  Orchard")
        title.font = .systemFont(ofSize: 22, weight: .bold)

        headlineLabel.font = .systemFont(ofSize: 13)
        headlineLabel.textColor = .secondaryLabelColor

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.addArrangedSubview(title)
        headerStack.addArrangedSubview(headlineLabel)
        headerStack.addArrangedSubview(progressBar)
        container.addSubview(headerStack)

        // ---- Card list (scrollable, mirroring the Runtimes pane) ----------
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = SetupWindowLayout.rowSpacing
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        // Optional rows (gitea-token, container rows) grow the checklist past
        // the six rows the window was sized for — the list scrolls instead of
        // the window growing.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = rowsStack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        // ---- Footer -------------------------------------------------------
        let terminalButton = NSButton(title: "Run in Terminal", target: self, action: #selector(openTerminal))
        terminalButton.bezelStyle = .rounded
        terminalButton.controlSize = .regular
        terminalButton.setButtonType(.momentaryPushIn)

        startButton.bezelStyle = .rounded
        startButton.controlSize = .regular
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(startFleet)
        startButton.isEnabled = false

        let spacer = NSView()
        let footer = NSStackView(views: [terminalButton, spacer, startButton])
        footer.orientation = .horizontal
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: SetupWindowLayout.margin),
            headerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SetupWindowLayout.margin),
            headerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SetupWindowLayout.margin),
            headerStack.heightAnchor.constraint(equalToConstant: SetupWindowLayout.headerHeight),

            progressBar.leadingAnchor.constraint(equalTo: headerStack.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: headerStack.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: SetupWindowLayout.margin),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SetupWindowLayout.margin),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SetupWindowLayout.margin),
            // Zero gap: the visible area matches SetupWindowLayout's math
            // (visibleRowCount() == 6 at the default height), so the base
            // checklist fills the pane exactly and only the overflow scrolls.
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SetupWindowLayout.margin),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SetupWindowLayout.margin),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -SetupWindowLayout.margin),
            footer.heightAnchor.constraint(equalToConstant: SetupWindowLayout.footerHeight - SetupWindowLayout.margin),
        ])
    }

    // MARK: Rendering

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        Task { [weak self] in
            await self?.refreshChecks()
        }
    }

    func refreshChecks() async {
        let status = await SetupStatusComputer().compute()
        render(viewModel: SetupViewModel(status: status))
    }

    func render(viewModel: SetupViewModel) {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        headlineLabel.stringValue = viewModel.headline
        progressBar.doubleValue = viewModel.progressFraction
        progressBar.isHidden = viewModel.isLoading
        canStart = viewModel.canStart
        startButton.isEnabled = viewModel.canStart

        // The first unsatisfied row gets the prominent fix button.
        let pendingIndex = viewModel.rows.firstIndex { !$0.isSatisfied && !$0.isPlaceholder }

        for (index, row) in viewModel.rows.enumerated() {
            rowsStack.addArrangedSubview(makeCard(for: row, prominent: index == pendingIndex))
        }

        // Render diagnostics: card + button geometry lands in the log so a
        // misplaced-content regression is observable without a screenshot.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, let window = self.window else { return }
            window.layoutIfNeeded()
            for card in self.rowsStack.arrangedSubviews {
                let buttons = card.subviews.compactMap { $0 as? NSButton }
                let buttonsText = buttons
                    .map { "btn(\($0.title) [\($0.identifier?.rawValue ?? "?")])@\(Int($0.frame.minX)),\(Int($0.frame.minY))" }
                    .joined(separator: " ")
                let title = card.subviews.compactMap { $0 as? NSStackView }.first?
                    .arrangedSubviews.compactMap { $0 as? NSTextField }.first?.stringValue ?? "?"
                Log.info("setup", "card '\(title)' frame \(Int(card.frame.width))x\(Int(card.frame.height)) @\(Int(card.frame.origin.x)),\(Int(card.frame.origin.y)) \(buttonsText)")
            }
        }
    }

    /// A single checklist card.
    private func makeCard(for row: SetupRowViewModel, prominent: Bool) -> NSView {
        let card = NSView()
        // REQUIRED: the card carries explicit size anchors and lives inside a
        // stack view. Without this, the autoresizing mask becomes an
        // unsatisfiable constraint; AppKit breaks random constraints and the
        // card's contents (text, buttons) end up misplaced or invisible.
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = SetupWindowLayout.cardCornerRadius
        card.layer?.backgroundColor = (row.isSatisfied
            ? NSColor.labelColor.withAlphaComponent(0.045)
            : NSColor.controlBackgroundColor
        ).cgColor
        card.layer?.borderWidth = prominent ? 1.5 : (row.isSatisfied ? 0 : 1)
        card.layer?.borderColor = (prominent
            ? NSColor.controlAccentColor.withAlphaComponent(0.45)
            : NSColor.separatorColor
        ).cgColor

        // Status disc: ✓ when satisfied, ! when pending, … while checking.
        let disc = NSTextField(labelWithString: row.isPlaceholder ? "…" : (row.isSatisfied ? "✓" : "!"))
        disc.font = .systemFont(ofSize: 13, weight: .bold)
        disc.alignment = .center
        disc.wantsLayer = true
        disc.layer?.cornerRadius = 12
        disc.layer?.masksToBounds = true
        let discColor: NSColor = row.isPlaceholder
            ? .systemGray
            : (row.isSatisfied ? .systemGreen : .systemOrange)
        disc.layer?.backgroundColor = discColor.withAlphaComponent(0.18).cgColor
        disc.textColor = discColor
        disc.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: row.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor

        let subtitle = NSTextField(wrappingLabelWithString: row.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2
        // Wrap (not overflow) when the column is width-bounded.
        subtitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let column = NSStackView(views: [title, subtitle])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(disc)
        card.addSubview(column)

        var constraints = [
            disc.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            disc.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            disc.widthAnchor.constraint(equalToConstant: 24),
            disc.heightAnchor.constraint(equalToConstant: 24),

            column.leadingAnchor.constraint(equalTo: disc.trailingAnchor, constant: 12),
            // Bound the text column on the right ALWAYS — otherwise rows
            // without a fix button give the wrapping subtitle unbounded width
            // and the text draws outside the card.
            column.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -14),
            column.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            column.topAnchor.constraint(greaterThanOrEqualTo: card.topAnchor, constant: 8),
            column.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -8),
        ]

        if let actionTitle = row.actionTitle {
            let button = NSButton(title: actionTitle, target: self, action: #selector(runAction(_:)))
            button.translatesAutoresizingMaskIntoConstraints = false // constraints below conflict with the autoresizing mask otherwise
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            if prominent { button.keyEquivalent = "" }
            // Dispatch keys off the ACTION id ("install_tart"…), not the row id.
            button.identifier = NSUserInterfaceItemIdentifier(row.actionID ?? row.id)
            button.target = self
            card.addSubview(button)
            constraints.append(contentsOf: [
                button.leadingAnchor.constraint(greaterThanOrEqualTo: column.trailingAnchor, constant: 16),
                button.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
                button.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            ])
        }

        NSLayoutConstraint.activate(constraints)
        card.heightAnchor.constraint(equalToConstant: SetupWindowLayout.cardHeight).isActive = true
        card.widthAnchor.constraint(equalToConstant: SetupWindowLayout.windowWidth - SetupWindowLayout.margin * 2).isActive = true
        return card
    }

}
