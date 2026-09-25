import AppKit
import KinhinKit
import Observation
import SwiftUI

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

/// State behind the Logs viewer: the ring-buffer snapshot, the active filter,
/// and the rendered text. Filtering re-renders from the cached entries
/// without touching the ring buffer.
@MainActor
@Observable
final class LogsModel {
    static let levels: [(title: String, level: Log.Level)] = [
        ("All", .debug), ("Info+", .info), ("Warnings+", .warn), ("Errors", .error),
    ]

    private(set) var entries: [Log.Entry] = []
    private(set) var filter = LogEntryFilter()
    var follow = true
    /// The filtered log as colored monospaced text.
    private(set) var text = NSAttributedString()
    /// Bumped whenever `text` is replaced, so the text view only reloads on
    /// a real change (the timer re-reads every second).
    private(set) var revision = 0
    /// Bumped when the user changes the search, which always jumps to the
    /// newest match.
    private(set) var searchRevision = 0

    var query: String {
        get { filter.query }
        set {
            guard newValue != filter.query else { return }
            filter.query = newValue
            searchRevision += 1
            rebuild()
        }
    }

    var minLevel: Log.Level {
        get { filter.minLevel }
        set {
            guard newValue != filter.minLevel else { return }
            filter.minLevel = newValue
            rebuild()
        }
    }

    var statusText: String { "\(entries.count) lines" }

    /// Re-reads the log ring buffer and re-renders.
    func refresh() {
        let snapshot = Log.snapshot(limit: 2000)
        guard snapshot != entries || revision == 0 else { return }
        entries = snapshot
        rebuild()
    }

    private func rebuild() {
        let matching = entries.filter { filter.matches($0) }
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let full = NSMutableAttributedString()
        for entry in matching {
            let color: NSColor
            switch entry.level {
            case "error": color = .systemRed
            case "warn": color = .systemOrange
            case "debug": color = .secondaryLabelColor
            default: color = .labelColor
            }
            full.append(
                NSAttributedString(
                    string: entry.formatted + "\n", attributes: [.font: mono, .foregroundColor: color]))
        }
        if matching.isEmpty {
            full.append(
                NSAttributedString(
                    string: entries.isEmpty ? "No log lines yet." : "No lines match.",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
        }
        text = full
        revision += 1
    }
}

/// Toolbar (search, level, follow, line count) over the log text.
struct LogsView: View {
    @Bindable var model: LogsModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                TextField("Search logs (message, component, level)", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search logs")
                Picker("Level", selection: $model.minLevel) {
                    ForEach(LogsModel.levels, id: \.level) { item in
                        Text(item.title).tag(item.level)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Filter by log level")
                Toggle("Follow", isOn: $model.follow)
                    .font(.system(size: 12))
                Text(model.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            LogTextView(
                text: model.text, revision: model.revision, searchRevision: model.searchRevision,
                follow: model.follow
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        }
    }
}

/// The log body: a read-only `NSTextView`. SwiftUI `Text`/`List` stays slow
/// at ring-buffer size and loses text selection and Find, so this stays
/// AppKit.
private struct LogTextView: NSViewRepresentable {
    let text: NSAttributedString
    let revision: Int
    let searchRevision: Int
    let follow: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isRichText = false
        textView.autoresizingMask = [.width]
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.usesFindBar = true
        textView.setAccessibilityLabel("Log output")

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = coordinator.textView, let storage = textView.textStorage else { return }

        if coordinator.revision != revision {
            let wasAtBottom = coordinator.isAtBottom(scroll)
            let grew = text.length > coordinator.length
            storage.setAttributedString(text)
            let searched = coordinator.searchRevision != searchRevision
            if searched || (follow && (grew || wasAtBottom)) {
                coordinator.scrollToBottom(scroll)
            }
            coordinator.revision = revision
            coordinator.searchRevision = searchRevision
            coordinator.length = text.length
        } else if follow, !coordinator.follow {
            coordinator.scrollToBottom(scroll)
        }
        coordinator.follow = follow
    }

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        var revision = -1
        var searchRevision = 0
        var length = 0
        var follow = true

        /// Within a few lines of the end counts as "at the bottom", so a
        /// user who scrolled up to read is not yanked back down.
        func isAtBottom(_ scroll: NSScrollView) -> Bool {
            guard let textView else { return false }
            return NSMaxY(textView.bounds) <= NSMaxY(scroll.contentView.bounds) + 40
        }

        func scrollToBottom(_ scroll: NSScrollView) {
            guard let document = scroll.documentView else { return }
            document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - 10)))
        }
    }
}
