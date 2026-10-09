import Foundation

/// How many VMs the fleet has live, as a benchmark sees it.
public struct BenchmarkFleetImpact: Codable, Sendable, Equatable {
    public var active: Int
    public var busy: Int
    public var running: Bool
    public var paused: Bool

    public init(active: Int = 0, busy: Int = 0, running: Bool = false, paused: Bool = false) {
        self.active = active
        self.busy = busy
        self.running = running
        self.paused = paused
    }

    public init(_ status: FleetStatus) {
        self.init(
            active: status.records.filter { $0.phase.isActive }.count,
            busy: status.records.filter { $0.phase == .busy }.count,
            running: status.running, paused: status.paused)
    }
}

/// What a benchmark needs from the fleet it shares the Mac with: its load, and
/// a pause switch. The runner never starts or stops a fleet, it only holds
/// new spawns while it measures.
public protocol BenchmarkFleetControlling: Sendable {
    func impact() async throws -> BenchmarkFleetImpact
    func setPaused(_ paused: Bool) async throws
}

/// The fleet behind any `FleetServing` (the app's backend, the CLI's daemon client).
public struct ServingFleetControl: BenchmarkFleetControlling {
    let service: any FleetServing

    public init(_ service: any FleetServing) {
        self.service = service
    }

    public func impact() async throws -> BenchmarkFleetImpact {
        BenchmarkFleetImpact(try await service.status(includeUsage: false))
    }

    public func setPaused(_ paused: Bool) async throws {
        try await service.setPaused(paused)
    }
}

/// The engine itself, for a daemon or an in-process app that runs the benchmark.
struct EngineFleetControl: BenchmarkFleetControlling {
    let engine: FleetEngine

    func impact() async throws -> BenchmarkFleetImpact {
        BenchmarkFleetImpact(await engine.status(includeUsage: false))
    }

    func setPaused(_ paused: Bool) async throws {
        await engine.setPaused(paused)
    }
}

/// Pause, drain and resume around a run. `resume()` is safe to call whether or not `hold` paused anything.
actor FleetHold {
    private let fleet: BenchmarkFleetControlling
    private var pausedByUs = false

    init(fleet: BenchmarkFleetControlling) {
        self.fleet = fleet
    }

    /// Pauses a running, unpaused fleet and waits (bounded) for busy VMs to finish.
    func hold(force: Bool, drainSeconds: TimeInterval, poll: Duration = .seconds(2)) async throws {
        let before = try await fleet.impact()
        if before.running, !before.paused {
            try await fleet.setPaused(true)
            pausedByUs = true
            Log.info("bench", "fleet paused for the benchmark")
        }
        guard !force else { return }
        let deadline = Date().addingTimeInterval(drainSeconds)
        while true {
            let now = try await fleet.impact()
            if now.busy == 0 { return }
            if Date() >= deadline { throw BenchmarkError.drainTimeout(busy: now.busy) }
            try await Task.sleep(for: poll)
        }
    }

    func resume() async {
        guard pausedByUs else { return }
        pausedByUs = false
        do {
            try await fleet.setPaused(false)
            Log.info("bench", "fleet resumed")
        } catch {
            Log.warn("bench", "resuming the fleet failed: \(error.localizedDescription)")
        }
    }
}
