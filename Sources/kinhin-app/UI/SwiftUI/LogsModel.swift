import AppKit
import KinhinKit
import Observation

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

    var statusText: String { entries.count == 1 ? "1 line" : "\(entries.count) lines" }

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
