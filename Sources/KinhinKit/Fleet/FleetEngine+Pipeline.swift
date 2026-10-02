import Foundation
import Synchronization

// MARK: - Live pipeline lookup

extension FleetEngine {
    /// The pipeline the VM `vmID` is running (its jobs and their steps), or
    /// nil when it runs no job or its forge can't tell.
    ///
    /// Throws `EngineError.unknownVM` for an id that is not in the store. A
    /// VM with several runners (`runners_per_vm`) answers with the first
    /// runner that has a job.
    public func pipelineDetail(vmID: String) async throws -> PipelineDetail? {
        guard VMRecord.isValidID(vmID), let record = store.all.first(where: { $0.id == vmID }) else {
            throw EngineError.unknownVM(vmID)
        }
        guard record.phase == .busy || record.job != nil else { return nil }
        guard let platform = record.platform, let forge = forges[platform] else { return nil }
        if let cached = pipelineCache.value(for: vmID) { return cached.detail }
        if let limit = forge.rateLimit, limit.isLow { return pipelineCache.value(for: vmID, ignoringAge: true)?.detail }
        let repository = record.repos?.first
        var found: PipelineDetail?
        for runnerName in runnerNames(of: record) {
            if let detail = try await forge.pipelineDetail(runnerName: runnerName, repository: repository) {
                found = detail
                break
            }
        }
        pipelineCache.store(found, for: vmID)
        return found
    }

    /// The runner names a VM registered: its own id, or `<id>-rN` per runner.
    func runnerNames(of record: VMRecord) -> [String] {
        let count = max(1, config.runnersPerVM)
        return count == 1 ? [record.id] : (1...count).map { "\(record.id)-r\($0)" }
    }
}

// MARK: - Cache

final class PipelineDetailCache: Sendable {
    struct Entry: Sendable {
        let detail: PipelineDetail?
        let fetched: Date
    }

    private let entries = Mutex<[String: Entry]>([:])
    let ttl: TimeInterval

    init(ttl: TimeInterval = 2) {
        self.ttl = ttl
    }

    func value(for id: String, ignoringAge: Bool = false, now: Date = Date()) -> Entry? {
        guard let entry = entries.withLock({ $0[id] }) else { return nil }
        return ignoringAge || now.timeIntervalSince(entry.fetched) < ttl ? entry : nil
    }

    func store(_ detail: PipelineDetail?, for id: String, now: Date = Date()) {
        entries.withLock {
            $0[id] = Entry(detail: detail, fetched: now)
            // Bounded: drop entries long past their use.
            if $0.count > 64 { $0 = $0.filter { now.timeIntervalSince($0.value.fetched) < 60 } }
        }
    }
}
