import Foundation

/// What is running and what is waiting, and where each job comes from: the data behind `kinhin jobs` and
/// `kinhin queue`. Built from a `FleetStatus` so it works against a daemon and an in-process engine alike.
public struct FleetJobsReport: Codable, Sendable, Equatable {
    /// One job, running (it has a `vm`) or queued (it has a `position`).
    public struct Entry: Codable, Sendable, Equatable {
        public var name: String
        /// `owner/repo`, when the forge says (a repo-scope running job names none).
        public var repo: String?
        /// The forge account the job came from.
        public var forge: String
        /// Running only: the VM or container instance, and the runner on it.
        public var vm: String?
        public var runner: String?
        /// When the forge queued the job (nil when it does not say).
        public var enqueuedAt: Date?
        /// Running only: when it started (nil when the forge does not say).
        public var startedAt: Date?
        /// Queued only: 1-based place in the first-in, first-out line.
        public var position: Int?

        public init(
            name: String, repo: String? = nil, forge: String, vm: String? = nil, runner: String? = nil,
            enqueuedAt: Date? = nil, startedAt: Date? = nil, position: Int? = nil
        ) {
            self.name = name
            self.repo = repo
            self.forge = forge
            self.vm = vm
            self.runner = runner
            self.enqueuedAt = enqueuedAt
            self.startedAt = startedAt
            self.position = position
        }
    }

    /// Running jobs, oldest start first.
    public var running: [Entry]
    /// Queued jobs, oldest first (FIFO by created date; jobs without a date follow in forge order).
    public var queued: [Entry]
    /// Total queued jobs. Larger than `queued.count` when the status carried only the head of the line.
    public var queueDepth: Int
    /// Running VMs that are busy but whose job the forge has not named yet.
    public var unattributedBusy: [String]
    /// The queue counts per forge account.
    public var queueByForge: [String: Int]
    /// The Fleet is not running or has not polled yet.
    public var polled: Bool

    public init(
        running: [Entry] = [], queued: [Entry] = [], queueDepth: Int = 0, unattributedBusy: [String] = [],
        queueByForge: [String: Int] = [:], polled: Bool = false
    ) {
        self.running = running
        self.queued = queued
        self.queueDepth = queueDepth
        self.unattributedBusy = unattributedBusy
        self.queueByForge = queueByForge
        self.polled = polled
    }

    /// The report for `status`. An older daemon sends no queue list: `queued` is then empty while `queueDepth` and
    /// the per-repo counts still say how much waits.
    public init(status: FleetStatus) {
        var running: [Entry] = []
        var unattributed: [String] = []
        for record in status.records {
            let stamps = FleetStatusFormatter.runningJobs(of: record)
            if stamps.isEmpty, record.phase == .busy { unattributed.append(record.id) }
            for stamp in stamps {
                running.append(
                    Entry(
                        name: stamp.job, repo: stamp.repo, forge: record.platform ?? "", vm: record.id,
                        runner: stamp.runner, enqueuedAt: stamp.enqueuedAt, startedAt: stamp.startedAt))
            }
        }
        running.sort { Self.earlier($0.startedAt, $1.startedAt) }
        // The status counts a scale-set runner's job as demand until it ends; the report counts only waiting jobs.
        let waiting = status.queueByForge.map { $0.values.reduce(0, +) }
        self.init(
            running: running, queued: status.queuedJobs ?? [], queueDepth: waiting ?? status.queueDepth,
            unattributedBusy: unattributed.sorted(), queueByForge: status.queueByForge ?? [:],
            polled: status.queuePolledAt != nil)
    }

    /// Strictly-earlier ordering where a missing date sorts last.
    static func earlier(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (let a?, let b?): return a < b
        case (_?, nil): return true
        default: return false
        }
    }

    /// Queued entries in FIFO order with positions filled in: by created date, oldest first; entries without a date
    /// keep their given order after the dated ones. Stable, so equal dates keep forge order.
    public static func fifo(_ entries: [Entry]) -> [Entry] {
        var ordered = entries.enumerated().sorted { a, b in
            if a.element.enqueuedAt == b.element.enqueuedAt { return a.offset < b.offset }
            return earlier(a.element.enqueuedAt, b.element.enqueuedAt)
        }.map(\.element)
        for index in ordered.indices { ordered[index].position = index + 1 }
        return ordered
    }
}
