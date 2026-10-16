import Foundation

/// The bounded history of healing events, persisted owner-only next to the
/// fleet records so it survives a restart (`kinhin heal` after a daemon
/// restart still shows what was fixed). Pure value type plus file IO helpers.
struct HealingJournal: Sendable, Equatable {
    /// Events kept, newest last.
    static let capacity = 100

    private(set) var events: [HealingEvent] = []

    init(events: [HealingEvent] = []) {
        self.events = Array(events.suffix(Self.capacity))
    }

    mutating func append(_ event: HealingEvent) {
        events.append(event)
        if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
    }

    /// Applies `change` to the event `id`, stamping `updatedAt`. False when it is gone.
    @discardableResult
    mutating func update(_ id: String, now: Date = Date(), _ change: (inout HealingEvent) -> Void) -> Bool {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return false }
        change(&events[index])
        events[index].updatedAt = now
        return true
    }

    func event(_ id: String) -> HealingEvent? { events.first { $0.id == id } }

    /// The open event (pending, running or surfaced) for a problem, if any.
    func openEvent(for signalKey: String) -> HealingEvent? {
        events.last { $0.signal.key == signalKey && $0.isOpen }
    }

    /// Newest first, for clients.
    var newestFirst: [HealingEvent] { events.reversed() }

    // MARK: - Persistence

    static func fileURL(in directory: URL) -> URL { directory.appendingPathComponent("healing.json") }

    /// The journal at `url`. Open events from a previous run are closed as
    /// `expired`: nobody can approve a fix for an engine that is gone, and a
    /// problem that persists is raised again by the next pass. Missing reads
    /// as empty. An unreadable file is set aside (`StateFile`) so the next
    /// save cannot overwrite it — unless `readOnly` (the CLI's view of a
    /// stopped engine's journal must not move the daemon's files), which only
    /// logs and reads as empty.
    static func load(from url: URL, now: Date = Date(), readOnly: Bool = false) -> HealingJournal {
        let decode = { (data: Data) throws -> [HealingEvent] in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([HealingEvent].self, from: data)
        }
        let events: [HealingEvent]
        if readOnly {
            guard FileManager.default.fileExists(atPath: url.path) else { return HealingJournal() }
            do {
                events = try decode(Data(contentsOf: url))
            } catch {
                Log.warn("healing", "could not read \(url.path) (\(error.localizedDescription)); showing nothing")
                return HealingJournal()
            }
        } else {
            guard case .loaded(let loaded) = StateFile.load(url, component: "healing", now: now, decode: decode) else {
                return HealingJournal()
            }
            events = loaded
        }
        var journal = HealingJournal(events: events)
        for event in journal.events where event.isOpen {
            journal.update(event.id, now: now) { $0.outcome = .expired }
        }
        return journal
    }

    /// Best-effort: the journal is a history, never a source of truth.
    func save(to url: URL) {
        bestEffort("healing", "saving the healing journal") {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try Paths.writePrivateFile(try encoder.encode(events), to: url)
        }
    }
}
