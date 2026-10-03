import Foundation
import Synchronization

/// Gathers live CPU/RAM for the host and every fleet instance. Results are
/// cached briefly so the UI's few-second status poll does not spawn
/// `docker stats` or `ps` on every tick. Probe failures are logged and read
/// as "no usage" — they never fail a status read.
final class UsageSampler: Sendable {
    struct Snapshot: Sendable {
        var host: HostUsage?
        var byInstance: [String: ResourceUsage]
    }

    private struct State {
        var cached: (at: ContinuousClock.Instant, snapshot: Snapshot)?
        /// Last cumulative CPU reading per Tart VM, for rate calculation.
        var processCPU: [String: (seconds: Double, at: ContinuousClock.Instant)] = [:]
        /// The sample being taken, joined by every caller that arrives meanwhile.
        var inFlight: Task<Snapshot, Never>?
    }

    private let tart: TartControlling
    private let shell: ShellRunning
    private let hostProbe: HostUsageProbe
    private let tartMemoryMB: @Sendable () -> Int
    private let minInterval: Duration
    /// Past this age a snapshot is no longer served stale: the caller waits.
    private let maxStale: Duration
    private let state = Mutex(State())

    init(
        tart: TartControlling, shell: ShellRunning, hostProbe: HostUsageProbe = HostUsageProbe(),
        tartMemoryMB: @escaping @Sendable () -> Int, minInterval: Duration = .seconds(2),
        maxStale: Duration = .seconds(30)
    ) {
        self.tart = tart
        self.shell = shell
        self.hostProbe = hostProbe
        self.tartMemoryMB = tartMemoryMB
        self.minInterval = minInterval
        self.maxStale = maxStale
    }

    func snapshot(for records: [VMRecord]) async -> Snapshot {
        let now = ContinuousClock.now
        enum Step {
            case serve(Snapshot)
            case wait(Task<Snapshot, Never>)
        }
        let step = state.withLock { state -> Step in
            let cached = state.cached
            if let cached, now - cached.at < minInterval { return .serve(cached.snapshot) }
            let stale = cached.flatMap { now - $0.at < maxStale ? $0.snapshot : nil }
            if let running = state.inFlight {
                return stale.map(Step.serve) ?? .wait(running)
            }
            let task = Task { await self.sample(records: records) }
            state.inFlight = task
            return stale.map(Step.serve) ?? .wait(task)
        }
        switch step {
        case .serve(let snapshot): return snapshot
        case .wait(let task): return await task.value
        }
    }

    /// One real sampling pass; publishes the result and retires the in-flight record.
    private func sample(records: [VMRecord]) async -> Snapshot {
        let now = ContinuousClock.now
        let live = records.filter { $0.phase.isActive }
        let tartIDs = live.filter { ($0.runtime ?? RuntimeID.tart.rawValue) == RuntimeID.tart.rawValue }.map(\.id)
        let tools = Set(live.compactMap { Self.containerTool(for: $0.runtime) })

        var byInstance: [String: ResourceUsage] = [:]
        if !tartIDs.isEmpty { byInstance.merge(await tartUsage(names: tartIDs, now: now)) { $1 } }
        for tool in tools {
            do {
                byInstance.merge(try await ContainerManager(tool: tool, shell: shell).stats()) { $1 }
            } catch {
                Log.warn("usage", "\(tool.title) stats unavailable: \(error.localizedDescription)")
            }
        }
        let snapshot = Snapshot(host: hostProbe.sample(), byInstance: byInstance)
        state.withLock {
            $0.cached = (now, snapshot)
            $0.inFlight = nil
        }
        return snapshot
    }

    private static func containerTool(for runtime: String?) -> ContainerTool? {
        switch runtime {
        case RuntimeID.docker.rawValue: return .docker
        case RuntimeID.appleContainer.rawValue: return .appleContainer
        default: return nil
        }
    }

    private func tartUsage(names: [String], now: ContinuousClock.Instant) async -> [String: ResourceUsage] {
        let samples: [String: ProcessSample]
        do {
            samples = try await tart.processSamples(of: names)
        } catch {
            Log.warn("usage", "tart process stats unavailable: \(error.localizedDescription)")
            return [:]
        }
        let limit = tartMemoryMB()
        return state.withLock { state in
            var out: [String: ResourceUsage] = [:]
            for (name, sample) in samples {
                var cpu: Double?
                if let before = state.processCPU[name] {
                    let wall = (now - before.at) / .seconds(1)
                    if wall > 0, sample.cpuSeconds >= before.seconds {
                        cpu = (sample.cpuSeconds - before.seconds) / wall * 100
                    }
                }
                state.processCPU[name] = (sample.cpuSeconds, now)
                out[name] = ResourceUsage(
                    cpuPercent: cpu, memoryUsedMB: sample.rssMB, memoryLimitMB: limit > 0 ? limit : nil)
            }
            state.processCPU = state.processCPU.filter { samples[$0.key] != nil }
            return out
        }
    }
}
