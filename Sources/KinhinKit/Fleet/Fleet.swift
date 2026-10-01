import Foundation
import Synchronization

/// Lifecycle phases of a single runner VM.
public enum VMPhase: String, Codable, Sendable, CaseIterable {
    case cloning  // tart clone running
    case booting  // tart run launched, waiting for IP
    case registering  // SSH: config.sh + run.sh in flight
    case ready  // registered on GitHub, waiting for a job
    case busy  // runner picked up a job (busy=true)
    case deleting  // teardown in progress
    case failed  // hit an error; awaiting cleanup

    public var isActive: Bool {
        switch self {
        case .cloning, .booting, .registering, .ready, .busy: return true
        case .deleting, .failed: return false
        }
    }

    var isTerminal: Bool { self == .deleting || self == .failed }
}

/// Tracked state for one VM. Persisted as JSON for crash recovery.
public struct VMRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: String  // tart VM name, e.g. "kinhin-1717000000-a1b2"
    public var phase: VMPhase
    public var createdAt: Date
    var updatedAt: Date
    var runnerName: String?
    public var ip: String?
    /// Forge this VM serves ("github" | "gitea").
    public var platform: String?
    /// Execution runtime backing this instance ("tart"; docker/host in
    /// later stages). Nil on old records → treated as tart on read.
    public var runtime: String?
    public var job: String?
    /// Repositories with a job currently executing on this VM (org scope
    /// attribution, stamped by the reconcile loop from in-progress jobs;
    /// nil when nothing is running or the scope is a single repo).
    public var repos: [String]?
    public var error: String?

    public init(id: String, phase: VMPhase = .cloning, createdAt: Date = Date()) {
        self.id = id
        self.phase = phase
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// Ids kinhin generates are `kinhin-<ts>-<hex>`; anything else (a stray
    /// runner name, `..` segments) is never an instance of ours.
    static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^kinhin-[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil && !id.contains("..")
    }

    static func newName(now: Date = Date()) -> String {
        let ts = Int(now.timeIntervalSince1970)
        // 32 bits of entropy: names are drawn in bursts (scale-up) within the
        // same second, so 16 bits collided observably under test.
        let suffix = String(format: "%08x", UInt32.random(in: 0..<UInt32.max))
        return "kinhin-\(ts)-\(suffix)"
    }
}

/// Persistence for VM records so a crashed engine can reconcile on restart.
public final class FleetStore: Sendable {
    private let url: URL
    private let mutex: Mutex<[VMRecord]>

    public init(directory: URL = Paths.stateDirectory) {
        self.url = directory.appendingPathComponent("fleet.json")
        let loaded: [VMRecord] = {
            // A missing or corrupt fleet.json reads as "no fleet" — restart
            // recovery then adopts the live instances again. A corrupt one is
            // logged: its records (job/repo attribution) are lost.
            let file = directory.appendingPathComponent("fleet.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            do {
                return try JSONDecoder().decode([VMRecord].self, from: Data(contentsOf: file))
            } catch {
                Log.warn("store", "could not read \(file.path) (\(error.localizedDescription)); starting empty")
                return []
            }
        }()
        self.mutex = Mutex(loaded)
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
        let records = all
        let data = (try? JSONEncoder().encode(records)) ?? Data("[]".utf8)  // encode of VMRecord cannot fail
        // Failure is logged so a full disk does not go unnoticed.
        bestEffort("engine", "persisting \(records.count) VM record(s)") {
            try data.write(to: url, options: .atomic)
        }
    }
}

/// Pure desired-count policy, unit-testable without any I/O.
enum Autoscaler {
    /// How many runner VMs should exist right now.
    ///
    /// - queueDepth: label-matching queued jobs on GitHub
    /// - minRunners/maxRunners: config bounds
    /// - capacityCap: hard ceiling implied by host resources
    /// - runnersPerVM: registered runner processes per VM (many-to-one);
    ///   each VM absorbs this many queued jobs, so fewer VMs cover the queue
    static func desiredCount(
        queueDepth: Int,
        minRunners: Int,
        maxRunners: Int,
        capacityCap: Int,
        runnersPerVM: Int = 1
    ) -> Int {
        let cap = min(maxRunners, capacityCap)
        let demandVMs = Int(ceil(Double(queueDepth) / Double(max(1, runnersPerVM))))
        return min(max(demandVMs, minRunners), cap)
    }

    /// Total concurrent job slots the fleet offers: every VM (bounded by both
    /// config and host capacity) serves `runnersPerVM` jobs at once.
    static func jobCapacity(maxRunners: Int, capacityCap: Int, runnersPerVM: Int) -> Int {
        min(maxRunners, capacityCap) * max(1, runnersPerVM)
    }

    /// Records that count toward "a runner exists" (active phases only).
    static func activeCount(_ records: [VMRecord]) -> Int {
        records.count { $0.phase.isActive }
    }
}
