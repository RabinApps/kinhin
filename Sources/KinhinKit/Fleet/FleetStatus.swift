// FleetStatus — the shared status model, its actor box, and the client factory.
import Foundation

/// Everything the menu bar app and CLI need to know about the fleet.
public struct FleetStatus: Codable, Sendable, Equatable {
    public var running: Bool
    public var paused: Bool
    /// The engine's `auto_resume` policy. Nil from a daemon predating the
    /// field (treated as off) — same compat convention as `runtime`.
    public var autoResume: Bool?
    /// The engine's poll cadence, so pause/auto-resume hints can say when
    /// the queue is re-checked. Nil from a daemon predating the field.
    public var pollInterval: Int?
    /// The cadence the engine is actually polling at: `pollInterval`, or
    /// longer while idle or low on API budget (`pollSlowdown` says which).
    /// Nil before the first pass or from a daemon predating the field.
    public var currentPollInterval: Int?
    /// Why `currentPollInterval` exceeds `pollInterval` ("idle", "API budget
    /// low"); nil when it does not.
    public var pollSlowdown: String?
    /// When the tightest forge API budget resets, set while polling is slowed
    /// because that budget is running low; nil otherwise.
    public var rateLimitResetAt: Date?
    /// When the queue was last observed (a forge answered a demand fetch):
    /// the freshness of the queue numbers, distinct from `updatedAt` which
    /// every reconcile pass touches. Nil when never polled or from a daemon
    /// predating the field.
    public var queuePolledAt: Date?
    public var queueDepth: Int
    public var desired: Int
    public var capacityCap: Int
    /// Total concurrent job slots: VM cap × runners_per_vm (many-to-one).
    public var jobCapacity: Int
    /// Queued jobs grouped by repository (org scope only; empty for a
    /// single-repo fleet where the breakdown carries no information).
    public var queueByRepo: [String: Int]?
    /// Jobs currently executing, grouped by repository (org scope only;
    /// nil for a single-repo fleet).
    public var runningByRepo: [String: Int]?
    public var records: [VMRecord]
    /// Masked on assignment (see `VMRecord.error`).
    public var lastError: String? {
        didSet {
            if let lastError, LogRedactor.redact(lastError) != lastError {
                self.lastError = LogRedactor.redact(lastError)
            }
        }
    }
    /// Active problems, one per source, oldest first. `lastError` mirrors the
    /// newest, so a source that recovers clears only its own entry and an
    /// unrelated problem is never overwritten or left stale. Nil from a daemon
    /// predating the field.
    public var alerts: [FleetStatusAlert]?
    var updatedAt: Date
    /// Execution runtime serving the fleet ("tart" or "appleContainer").
    public var runtime: String?
    /// Set while a per-project image bakes: "baking image for acme/api
    /// (go@1.22.5), using base meanwhile". Nil when nothing is baking.
    public var imageNotice: String?
    /// A session-scoped warning the user can dismiss from the Fleet tab. Set
    /// while the engine holds spawns due to disk pressure; cleared when the
    /// condition eases. The app hides it once dismissed until the episode ends —
    /// the next episode (or a relaunch) shows it again, so a dismiss is "not now"
    /// rather than "fixed it for good".
    public var diskPressureNotice: String?
    /// Live host CPU/RAM. Nil when unmeasurable or from a daemon predating the field.
    public var host: HostUsage?
    /// Per-runtime capacity caps (mixed fleets: the weighted partition;
    /// nil for single-runtime fleets). Keys are RuntimeID raw values.
    public var capacityByRuntime: [String: String]?

    public init(
        running: Bool = false, paused: Bool = false, autoResume: Bool? = nil, pollInterval: Int? = nil,
        queuePolledAt: Date? = nil, queueDepth: Int = 0, desired: Int = 0, capacityCap: Int = 0,
        jobCapacity: Int = 0, queueByRepo: [String: Int]? = nil, runningByRepo: [String: Int]? = nil,
        records: [VMRecord] = [], lastError: String? = nil, updatedAt: Date = Date(), runtime: String? = nil,
        capacityByRuntime: [String: String]? = nil, diskPressureNotice: String? = nil
    ) {
        self.running = running
        self.paused = paused
        self.autoResume = autoResume
        self.pollInterval = pollInterval
        self.queuePolledAt = queuePolledAt
        self.queueDepth = queueDepth
        self.desired = desired
        self.capacityCap = capacityCap
        self.jobCapacity = jobCapacity
        self.queueByRepo = queueByRepo
        self.runningByRepo = runningByRepo
        self.records = records
        self.lastError = lastError
        self.updatedAt = updatedAt
        self.runtime = runtime
        self.capacityByRuntime = capacityByRuntime
        self.diskPressureNotice = diskPressureNotice
    }

    public var activeCount: Int { records.filter { $0.phase.isActive }.count }

    /// The countdown-style clause for a paused fleet with auto-resume on:
    /// when the queue is re-checked and what an empty check does. Nil
    /// whenever the hint does not apply — not paused, policy off, or an
    /// older daemon that does not report the cadence (surfaces fall back to
    /// their pre-cadence wording then).
    public var autoResumeCadence: String? {
        guard paused, autoResume == true, let poll = pollInterval else { return nil }
        return "re-checks the queue every \(poll)s and resumes once it's empty"
    }

    /// Seconds since a forge last answered a queue poll: the freshness of
    /// the queue numbers (`queueDepth`). Nil when never polled — there is
    /// no observation to date an age from. Clock skew clamps to 0.
    public var queueAgeSeconds: Int? {
        queuePolledAt.map { max(0, Int(Date().timeIntervalSince($0))) }
    }

    /// Whether that observation is older than the engine's cadence — a
    /// forge poll failed or the engine stopped, so the queue numbers may
    /// be outdated. The cadence is the one in effect (an idle backoff is not
    /// staleness). Without a known cadence (an older daemon) any nonzero age
    /// counts as stale, matching the CLI's `?? 0` rule. Nil when never
    /// polled: neither fresh nor stale.
    public var queueAgeIsStale: Bool? {
        guard let age = queueAgeSeconds else { return nil }
        return age > (currentPollInterval ?? pollInterval ?? 0)
    }
}

/// One active problem and the subsystem that raised it.
public struct FleetStatusAlert: Codable, Sendable, Equatable {
    /// Stable key of the raising subsystem (`"reconcile"`, `"queue:<account>"`…).
    public var source: String
    public var message: String
}

extension FleetStatus {
    /// Raises (`message` non-nil) or clears (nil) the alert of `source`, then
    /// refreshes `lastError` to the newest remaining alert. Re-raising an
    /// existing source moves it to the front of attention (newest).
    public mutating func setAlert(_ source: String, _ message: String?) {
        var list = alerts ?? []
        list.removeAll { $0.source == source }
        if let message { list.append(FleetStatusAlert(source: source, message: LogRedactor.redact(message))) }
        alerts = list.isEmpty ? nil : list
        lastError = list.last?.message
    }
}

/// actor wrapper so concurrent status reads are safe.
actor FleetStatusBox {
    private var status: FleetStatus
    init(_ status: FleetStatus = FleetStatus()) {
        self.status = status
    }
    func get() -> FleetStatus { status }
    func set(_ s: FleetStatus) { status = s }
    func modify(_ body: (inout FleetStatus) -> Void) { body(&status) }
}
