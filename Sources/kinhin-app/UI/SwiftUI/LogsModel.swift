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

    /// Lines kept in the view; the buffer may run `slack` past it before
    /// the oldest lines are dropped (so a busy log does not reload the whole
    /// text on every refresh).
    static let capacity = 2000
    static let slack = 500

    private(set) var entries: [Log.Entry] = []
    private(set) var filter = LogEntryFilter()
    var follow = true
    /// The filtered log as colored monospaced text.
    private(set) var text = NSAttributedString()
    /// Bumped on every change to `text`.
    private(set) var revision = 0
    /// Bumped when `text` was replaced (filter change, trim, first load)
    /// rather than appended to: the view reloads everything.
    private(set) var rebuildRevision = 0
    /// What the last append added, valid when `rebuildRevision` did not
    /// change: the view appends it instead of reloading the whole text.
    private(set) var appended = NSAttributedString()
    /// Bumped when the user changes the search, which always jumps to the
    /// newest match.
    private(set) var searchRevision = 0

    /// Formatted lines by sequence number (formatting is the costly part of
    /// a rebuild, and filter changes rebuild from the same entries).
    private var lineCache: [UInt64: NSAttributedString] = [:]
    private var showingPlaceholder = false

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

    /// Reads the log lines newer than the last refresh and appends them.
    func refresh() {
        refresh(from: Log.snapshot(limit: Self.capacity))
    }

    /// The incremental core (the snapshot is injectable for tests).
    func refresh(from snapshot: [Log.Entry]) {
        guard let newest = snapshot.last else {
            if revision == 0 { rebuild() }
            return
        }
        guard let lastSeq = entries.last?.seq, lastSeq != 0 else {
            entries = snapshot
            rebuild()
            return
        }
        if newest.seq == lastSeq { return }  // nothing new
        let fresh = snapshot.filter { $0.seq > lastSeq }
        // A window with nothing in common with ours (more new lines than it
        // holds) or a placeholder on screen: start over.
        if fresh.count == snapshot.count || showingPlaceholder {
            entries = snapshot
            rebuild()
            return
        }
        entries.append(contentsOf: fresh)
        if entries.count > Self.capacity + Self.slack {
            entries.removeFirst(entries.count - Self.capacity)
            let live = Set(entries.map(\.seq))
            lineCache = lineCache.filter { live.contains($0.key) }
            rebuild()
            return
        }
        let matching = fresh.filter { filter.matches($0) }
        guard !matching.isEmpty else { return }
        let chunk = NSMutableAttributedString()
        for entry in matching { chunk.append(line(for: entry)) }
        let full = NSMutableAttributedString(attributedString: text)
        full.append(chunk)
        text = full
        appended = chunk
        revision += 1
    }

    private func line(for entry: Log.Entry) -> NSAttributedString {
        if entry.seq != 0, let cached = lineCache[entry.seq] { return cached }
        let color: NSColor
        switch entry.level {
        case "error": color = .systemRed
        case "warn": color = .systemOrange
        case "debug": color = .secondaryLabelColor
        default: color = .labelColor
        }
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let line = NSAttributedString(
            string: entry.formatted + "\n", attributes: [.font: mono, .foregroundColor: color])
        if entry.seq != 0 { lineCache[entry.seq] = line }
        return line
    }

    private func rebuild() {
        let matching = entries.filter { filter.matches($0) }
        let full = NSMutableAttributedString()
        for entry in matching { full.append(line(for: entry)) }
        showingPlaceholder = matching.isEmpty
        if matching.isEmpty {
            full.append(
                NSAttributedString(
                    string: entries.isEmpty ? "No log lines yet." : "No lines match.",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
        }
        // Lines of entries no longer shown must not pin memory.
        if lineCache.count > Self.capacity + Self.slack {
            let live = Set(entries.map(\.seq))
            lineCache = lineCache.filter { live.contains($0.key) }
        }
        text = full
        appended = NSAttributedString()
        rebuildRevision += 1
        revision += 1
    }
}
