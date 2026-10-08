import Foundation
import Synchronization

/// Persistence for VM records so a crashed engine can reconcile on restart.
public final class FleetStore: Sendable {
    private let url: URL
    private let mutex: Mutex<[VMRecord]>
    /// Serializes file writes. Each write takes its snapshot while holding
    /// this, so the last write to land is always the newest state.
    private let writeLock = Mutex(())

    public init(directory: URL = Paths.stateDirectory) {
        self.url = directory.appendingPathComponent("fleet.json")
        // A missing or corrupt fleet.json reads as "no fleet" — restart
        // recovery then adopts the live instances again. A corrupt one is
        // logged: its records (job/repo attribution) are lost.
        self.mutex = Mutex(Self.readRecords(at: url) ?? [])
    }

    /// The records in `file`; nil when it is missing or unreadable.
    private static func readRecords(at file: URL) -> [VMRecord]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            return try JSONDecoder().decode([VMRecord].self, from: Data(contentsOf: file))
        } catch {
            Log.warn("store", "could not read \(file.path) (\(error.localizedDescription)); starting empty")
            return nil
        }
    }

    /// Re-reads fleet.json, replacing the in-memory records. A store built
    /// before another engine finished writing (the daemon builds a replacement
    /// engine while the old one still runs) holds stale records; the engine
    /// calls this once the previous owner is detached, so recovery adopts what
    /// that engine last wrote instead of what the file held at construction.
    /// A missing or unreadable file keeps the records in memory (the write
    /// that would have produced it may have failed).
    func reload() {
        writeLock.withLock { _ in
            guard let records = Self.readRecords(at: url) else { return }
            mutex.withLock { $0 = records }
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
