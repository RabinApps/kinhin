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
        /// The same baseline for a container's cumulative counter (apple's
        /// `cpuUsageUsec`; docker reports a rate and never lands here).
        var containerCPU: [String: (seconds: Double, at: ContinuousClock.Instant)] = [:]
        /// The sample being taken, joined by every caller that arrives meanwhile.
        var inFlight: Task<Snapshot, Never>?
    }

    private let tart: TartControlling
    private let shell: ShellRunning
    private let hostProbe: HostUsageProbe
    private let tartMemoryMB: @Sendable () -> Int
    /// vCPUs per Tart VM; the host process's CPU rate is divided by this.
    private let tartCPUCount: @Sendable () -> Int
    /// Builds the per-tool container client (tests inject a canned binary).
    private let makeContainer: @Sendable (ContainerTool, ShellRunning) -> ContainerManager
    private let minInterval: Duration
    /// Past this age a snapshot is no longer served stale: the caller waits.
    private let maxStale: Duration
    private let state = Mutex(State())

    init(
        tart: TartControlling, shell: ShellRunning, hostProbe: HostUsageProbe = HostUsageProbe(),
        tartMemoryMB: @escaping @Sendable () -> Int, tartCPUCount: @escaping @Sendable () -> Int = { 1 },
        minInterval: Duration = .seconds(2),
        maxStale: Duration = .seconds(30),
        makeContainer: @escaping @Sendable (ContainerTool, ShellRunning) -> ContainerManager = {
            ContainerManager(tool: $0, shell: $1)
        }
    ) {
        self.tart = tart
        self.shell = shell
        self.hostProbe = hostProbe
        self.tartMemoryMB = tartMemoryMB
        self.tartCPUCount = tartCPUCount
        self.makeContainer = makeContainer
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
        let tartIDs = live.filter { $0.runtime == nil || $0.runtimeID == .tart }.map(\.id)
        let tools = Set(live.compactMap { Self.containerTool(for: $0.runtimeID) })

        var byInstance: [String: ResourceUsage] = [:]
        if !tartIDs.isEmpty { byInstance.merge(await tartUsage(names: tartIDs, now: now)) { $1 } }
        var seenContainers = Set<String>()
        for tool in tools {
            do {
                let stats = try await makeContainer(tool, shell).statsWithCounters()
                seenContainers.formUnion(stats.keys)
                for (key, entry) in stats {
                    var usage = entry.usage
                    if usage.cpuPercent == nil {
                        usage.cpuPercent = containerRate(key: key, seconds: entry.cpuSeconds, now: now)
                    }
                    byInstance[key] = usage
                }
            } catch {
                Log.warn("usage", "\(tool.title) stats unavailable: \(error.localizedDescription)")
            }
        }
        state.withLock { $0.containerCPU = $0.containerCPU.filter { seenContainers.contains($0.key) } }
        let snapshot = Snapshot(host: hostProbe.sample(), byInstance: byInstance)
        state.withLock {
            $0.cached = (now, snapshot)
            $0.inFlight = nil
        }
        return snapshot
    }

    private static func containerTool(for runtime: RuntimeID?) -> ContainerTool? {
        switch runtime {
        case .docker: return .docker
        case .appleContainer: return .appleContainer
        default: return nil
        }
    }

    /// A container's cumulative CPU counter → percent of one core, from the
    /// delta since the previous sample. The first sample only starts the
    /// baseline and reports nil — the same rule as a Tart VM's first reading.
    private func containerRate(key: String, seconds: Double?, now: ContinuousClock.Instant) -> Double? {
        guard let seconds else { return nil }
        return state.withLock { state in
            defer { state.containerCPU[key] = (seconds, now) }
            guard let before = state.containerCPU[key], seconds >= before.seconds else { return nil }
            let wall = (now - before.at) / .seconds(1)
            guard wall > 0 else { return nil }
            return (seconds - before.seconds) / wall * 100
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
        let cores = Double(max(1, tartCPUCount()))
        // The host process maps all guest RAM, so ask the guest for its real use.
        var guestMB: [String: Int] = [:]
        await withTaskGroup(of: (String, Int?).self) { group in
            for name in samples.keys { group.addTask { (name, await self.tart.guestMemoryUsedMB(of: name)) } }
            for await (name, mb) in group { if let mb { guestMB[name] = mb } }
        }
        return state.withLock { state in
            var out: [String: ResourceUsage] = [:]
            for (name, sample) in samples {
                var cpu: Double?
                if let before = state.processCPU[name] {
                    let wall = (now - before.at) / .seconds(1)
                    if wall > 0, sample.cpuSeconds >= before.seconds {
                        // Percent of the VM's own cores, like the host line.
                        cpu = min(100, (sample.cpuSeconds - before.seconds) / wall * 100 / cores)
                    }
                }
                state.processCPU[name] = (sample.cpuSeconds, now)
                // The host process carries its own overhead above the guest:
                // never report more than the guest is allowed.
                let hostMB = guestMB[name] ?? sample.rssMB
                let usedMB = limit > 0 ? min(hostMB, limit) : hostMB
                out[name] = ResourceUsage(
                    cpuPercent: cpu, memoryUsedMB: usedMB, memoryLimitMB: limit > 0 ? limit : nil)
            }
            state.processCPU = state.processCPU.filter { samples[$0.key] != nil }
            return out
        }
    }
}
