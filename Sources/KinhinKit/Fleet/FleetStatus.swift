// FleetStatus — the shared status model, its actor box, and the client factory.
import Foundation

/// Everything the menu bar app and CLI need to know about the fleet.
public struct FleetStatus: Codable, Sendable, Equatable {
    public var running: Bool
    public var paused: Bool
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
    public var lastError: String?
    var updatedAt: Date
    /// Execution runtime serving the fleet ("tart" or "appleContainer").
    public var runtime: String?
    /// Per-runtime capacity caps (mixed fleets: the weighted partition;
    /// nil for single-runtime fleets). Keys are RuntimeID raw values.
    var capacityByRuntime: [String: String]?

    public init(
        running: Bool = false, paused: Bool = false, queueDepth: Int = 0, desired: Int = 0, capacityCap: Int = 0,
        jobCapacity: Int = 0, queueByRepo: [String: Int]? = nil, runningByRepo: [String: Int]? = nil,
        records: [VMRecord] = [], lastError: String? = nil, updatedAt: Date = Date(), runtime: String? = nil,
        capacityByRuntime: [String: String]? = nil
    ) {
        self.running = running
        self.paused = paused
        self.queueDepth = queueDepth
        self.desired = desired
        self.capacityCap = capacityCap
        self.jobCapacity = jobCapacity
        self.queueByRepo = queueByRepo
        self.runningByRepo = runningByRepo
        self.queueByRepo = queueByRepo
        self.records = records
        self.lastError = lastError
        self.updatedAt = updatedAt
    }

    public var activeCount: Int { records.filter { $0.phase.isActive }.count }
}

/// actor wrapper so concurrent status reads are safe.
actor FleetStatusBox {
    private var status: FleetStatus
    public init(_ status: FleetStatus = FleetStatus()) {
        self.status = status
    }
    public func get() -> FleetStatus { status }
    public func set(_ s: FleetStatus) { status = s }
    func modify(_ body: (inout FleetStatus) -> Void) { body(&status) }
}

/// Builds GitHub API clients for the engine. Injectable in tests; the
/// production instance rebuilds clients when the user replaces their PAT so
/// the swap takes effect without restarting the engine.
public struct GitHubClientFactory: Sendable {
    public var make: @Sendable (GitHubCredentials) -> GitHubServing

    public init(make: @escaping @Sendable (GitHubCredentials) -> GitHubServing) {
        self.make = make
    }

    /// Production factory: real GitHubClient instances.
    public static var live: GitHubClientFactory {
        GitHubClientFactory { GitHubClient(credentials: $0) }
    }
}
