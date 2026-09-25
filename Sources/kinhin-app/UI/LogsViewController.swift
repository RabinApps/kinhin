import AppKit
import KinhinKit

/// The Logs tab: a pretty, searchable view of kinhin's own log stream.
/// Renders Log ring-buffer entries (mirrored from kinhin.log) with level
/// coloring, pauseable auto-refresh, level filtering, and incremental text
/// search — no more digging through `kinhin logs` output in Terminal.
@MainActor
final class LogsViewController: NSViewController {
    private let textView = NSTextView()
    private let searchField = NSSearchField(frame: .zero)
    private let levelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let followButton = NSButton(checkboxWithTitle: "Follow", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var refreshTimer: Timer?
    /// Cache of the last rendered entries, so filtering re-renders without
    /// touching the ring buffer.
    private var entries: [Log.Entry] = []

    /// Match against level, component, or message — case-insensitive.
    struct LogEntryFilter {
        var query: String = ""
        var minLevel: Log.Level = .debug

        func matches(_ entry: Log.Entry) -> Bool {
            guard let level = Log.Level(rawValue: entry.level), level >= minLevel else { return false }
            guard !query.isEmpty else { return true }
            return entry.message.localizedCaseInsensitiveContains(query)
                || entry.component.localizedCaseInsensitiveContains(query)
                || entry.level.localizedCaseInsensitiveContains(query)
        }
    }

    private var filter = LogEntryFilter()

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("LogsViewController is created in code")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        // ---- Toolbar row --------------------------------------------------
        searchField.placeholderString = "Search logs (message, component, level)"
        searchField.controlSize = .regular
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityLabel("Search logs")

        for (title, level) in [
            ("All", Log.Level.debug), ("Info+", Log.Level.info), ("Warnings+", Log.Level.warn),
            ("Errors", Log.Level.error),
        ] {
            levelPopup.addItem(withTitle: title)
            levelPopup.lastItem?.representedObject = level
        }
        levelPopup.sizeToFit()
        levelPopup.target = self
        levelPopup.action = #selector(levelChanged)
        levelPopup.setAccessibilityLabel("Filter by log level")

        followButton.target = self
        followButton.action = #selector(followToggled)
        followButton.state = .on
        followButton.font = .systemFont(ofSize: 12)

        let toolbar = NSStackView(views: [searchField, levelPopup, followButton, statusLabel])
        toolbar.orientation = .horizontal
        toolbar.spacing = 10
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor

        // ---- Log text ------------------------------------------------------
        textView.isEditable = false
        textView.isRichText = false
        textView.autoresizingMask = [.width]
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Log output")

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let card = LayerStyleView(frame: .zero)
        card.styleLayer = { layer in
            layer.cornerRadius = 8
            layer.borderWidth = 1
            layer.borderColor = NSColor.separatorColor.cgColor
        }
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scroll)

        container.addSubview(toolbar)
        container.addSubview(card)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            card.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        view = container
        refreshNow()
        startTimer()
    }

    private func startTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            // A repeating timer outlives its owner; stop it once the view is gone.
            guard self != nil else { return timer.invalidate() }
            Task { @MainActor [weak self] in
                self?.refreshNow(keepScroll: true)
            }
        }
    }

    /// Re-reads the log ring buffer and re-renders. When follow is on and
    /// the user is at the bottom, the view stays pinned to the newest line.
    func refreshNow(keepScroll: Bool = false) {
        let previousCount = entries.count
        entries = Log.snapshot(limit: 2000)
        render()

        let atBottom = keepScroll && isAtBottom()
        let grew = entries.count > previousCount
        if keepScroll, followButton.state == .on, grew || atBottom {
            scrollToBottom()
        }
        statusLabel.stringValue = "\(entries.count) lines"
    }

    private func render() {
        guard let storage = textView.textStorage else { return }
        storage.setAttributedString(NSAttributedString(string: ""))
        let matching = entries.filter { filter.matches($0) }

        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let base: [NSAttributedString.Key: Any] = [
            .font: mono,
            .foregroundColor: NSColor.labelColor,
        ]
        let full = NSMutableAttributedString()
        for entry in matching {
            let color: NSColor
            switch entry.level {
            case "error": color = .systemRed
            case "warn": color = .systemOrange
            case "debug": color = .secondaryLabelColor
            default: color = .labelColor
            }
            var line = base
            line[.foregroundColor] = color
            full.append(NSAttributedString(string: entry.formatted + "\n", attributes: line))
        }
        if matching.isEmpty {
            let empty = base.merge([
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 12),
            ])
            full.append(
                NSAttributedString(
                    string: entries.isEmpty ? "No log lines yet." : "No lines match.",
                    attributes: empty
                ))
        }
        storage.setAttributedString(full)
    }

    private func isAtBottom() -> Bool {
        guard let scroll = textView.enclosingScrollView else { return false }
        return NSMaxY(textView.bounds) <= NSMaxY(scroll.contentView.bounds) + 40
    }

    private func scrollToBottom() {
        guard let document = textView.enclosingScrollView?.documentView else { return }
        document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - 10)))
    }

    // MARK: Actions

    @objc private func searchChanged() {
        filter.query = searchField.stringValue
        render()
        scrollToBottom()
    }

    @objc private func levelChanged() {
        filter.minLevel = (levelPopup.selectedItem?.representedObject as? Log.Level) ?? .debug
        render()
    }

    @objc private func followToggled() {
        if followButton.state == .on { scrollToBottom() }
    }
}

private extension Dictionary where Key == NSAttributedString.Key, Value == Any {
    func merge(_ other: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var result = self
        for (key, value) in other { result[key] = value }
        return result
    }
}
