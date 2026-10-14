import Foundation
import Synchronization

/// Persistence for VM records so a crashed engine can reconcile on restart.
public final class FleetStore: Sendable {
    private let url: URL
    private let mutex: Mutex<[VMRecord]>
    /// Serializes file writes. Each write takes its snapshot while holding
    /// this, so the last write to land is always the newest state.
    private let writeLock = Mutex(())

    /// Where an unreadable fleet.json found at construction or reload was
    /// set aside (see `StateFile`); nil when none was.
    private let corruptFile: Mutex<URL?>

    public init(directory: URL = Paths.stateDirectory) {
        self.url = directory.appendingPathComponent("fleet.json")
        // A missing fleet.json reads as "no fleet". A corrupt one is moved
        // aside and reported: restart recovery adopts the live instances
        // again, but their records (job/repo attribution) are lost.
        var initial: [VMRecord] = []
        var corrupt: URL?
        switch Self.readRecords(at: url) {
        case .missing: break
        case .loaded(let records): initial = records
        case .corrupt(let kept): corrupt = kept
        }
        self.mutex = Mutex(initial)
        self.corruptFile = Mutex(corrupt)
    }

    private static func readRecords(at file: URL) -> StateFile.Load<[VMRecord]> {
        StateFile.load(file, component: "store") { try JSONDecoder().decode([VMRecord].self, from: $0) }
    }

    /// Where an unreadable fleet.json was moved aside (or, if that move
    /// failed, its original path); nil when the file read cleanly or was
    /// missing. The engine raises it as a status alert.
    public var recoveredFromCorruptFile: URL? { corruptFile.withLock { $0 } }

    /// Re-reads fleet.json, replacing the in-memory records. A store built
    /// before another engine finished writing (the daemon builds a replacement
    /// engine while the old one still runs) holds stale records; the engine
    /// calls this once the previous owner is detached, so recovery adopts what
    /// that engine last wrote instead of what the file held at construction.
    /// A missing or unreadable file keeps the records in memory (the write
    /// that would have produced it may have failed); an unreadable one is
    /// also moved aside and reported like a corrupt file at construction.
    func reload() {
        writeLock.withLock { _ in
            switch Self.readRecords(at: url) {
            case .missing: return
            case .loaded(let records): mutex.withLock { $0 = records }
            case .corrupt(let kept): corruptFile.withLock { $0 = kept }
            }
        }
    }

    public var all: [VMRecord] { mutex.withLock { $0 } }

    func upsert(_ record: VMRecord) {
        mutex.withLock { list in
            if let idx = list.firstIndex(where: { $0.id == record.id }) {
                list[idx] = record
            } else {
                list.append(record)
            }
        }
        persist()
    }

    /// Mutates the record `id` atomically under the store lock (a read-modify-
    /// write through `all` + `upsert` could lose a concurrent update). Returns
    /// false when the record no longer exists; never recreates it. A mutation
    /// that changes nothing is not stamped or persisted.
    @discardableResult
    func update(id: String, _ mutate: (inout VMRecord) -> Void) -> Bool {
        let outcome = mutex.withLock { list -> (found: Bool, changed: Bool) in
            guard let idx = list.firstIndex(where: { $0.id == id }) else { return (false, false) }
            var record = list[idx]
            mutate(&record)
            guard record != list[idx] else { return (true, false) }
            record.updatedAt = Date()
            list[idx] = record
            return (true, true)
        }
        if outcome.changed { persist() }
        return outcome.found
    }

    public func remove(id: String) {
        mutex.withLock { list in
            list.removeAll { $0.id == id }
        }
        persist()
    }

    func replaceAll(_ records: [VMRecord]) {
        mutex.withLock { $0 = records }
        persist()
    }

    /// Best-effort crash journal: the authoritative record lives on the
    /// forges, so a failed write only degrades restart reconciliation.
    func persist() {
        writeLock.withLock { _ in
            let records = all
            let data = (try? JSONEncoder().encode(records)) ?? Data("[]".utf8)  // encode of VMRecord cannot fail
            // Failure is logged so a full disk does not go unnoticed.
            bestEffort("engine", "persisting \(records.count) VM record(s)") {
                try data.write(to: url, options: .atomic)
                try Paths.restrictToOwner(url)
            }
        }
    }
}
