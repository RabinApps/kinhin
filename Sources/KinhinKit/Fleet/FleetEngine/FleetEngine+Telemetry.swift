import Foundation

/// Which healing events `kinhin.healing.actions` has counted, and whether the journal's history was skipped yet.
struct HealingCounted {
    var seen: Set<String> = []
    var baselined = false
}

// FleetEngine — telemetry recording: per-instance traces, phase timings, job pickup and completion,
// and error counts. Every method is a no-op while the handle is the no-op one.
extension FleetEngine {
    /// The bounded metric attributes of an instance: pool (runtime), image and forge.
    func metricAttributes(of id: String) -> MetricAttributes {
        let record = store.all.first { $0.id == id }
        return [
            "pool": record?.runtime ?? RuntimeID.tart.rawValue, "image": record?.image ?? "default",
            "forge": record?.platform ?? ForgeID.github.rawValue,
        ]
    }

    func makeJobTrace(id: String) -> JobTrace {
        let attributes = metricAttributes(of: id)
        let record = store.all.first { $0.id == id }
        return JobTrace(
            telemetry: telemetry, vm: id, pool: attributes["pool"] ?? "tart", image: attributes["image"] ?? "default",
            forge: attributes["forge"] ?? "github", labels: record.flatMap { poolLabels(for: $0) })
    }

    func jobTrace(for id: String) -> JobTrace? { jobTraces.withLock { $0[id] } }

    /// The bounded `kinhin.result` of a trace for a delete reason (reasons carry free text, such as an error message).
    static func traceResult(forDeleteReason reason: String) -> String {
        if reason == "jobs finished" { return "completed" }
        if reason.hasPrefix("failed") { return "failed" }
        if reason.hasPrefix("scale down") || reason == "cancelled remotely" { return "scaled_down" }
        if reason.contains("evicted") { return "evicted" }
        if reason.contains("timeout") { return "timeout" }
        return "deleted"
    }

    func endJobTrace(id: String, result: String, error: String?) {
        let trace = jobTraces.withLock { $0.removeValue(forKey: id) }
        trace?.finish(result: result, error: error)
    }

    /// Times one lifecycle call with the monotonic clock: a histogram sample and a child span; a
    /// failure counts once in `kinhin.errors`, classified by the phase it happened in.
    func timed<T>(_ phase: Metric.Phase, id: String, _ body: () async throws -> T) async throws -> T {
        guard telemetry.isEnabled else { return try await body() }
        let trace = jobTrace(for: id)
        trace?.begin(phase)
        let start = ContinuousClock.now
        do {
            let value = try await body()
            telemetry.record(
                .phaseDuration, seconds: (ContinuousClock.now - start) / .seconds(1),
                metricAttributes(of: id).merging(["phase": phase.rawValue]) { $1 })
            trace?.end(phase)
            return value
        } catch {
            // A cancelled lifecycle (engine hand-over, stop) is not a failure, whatever error the callee surfaced.
            let cancelled = error is CancellationError || Task.isCancelled
            trace?.end(phase, error: cancelled ? "cancelled" : "\(phase.rawValue) failed")
            if !cancelled, trace?.claimErrorCount() ?? true {
                countError(TelemetryErrorType.classify(error, stage: phase), component: .lifecycle)
            }
            throw error
        }
    }

    func countError(_ type: TelemetryErrorType, component: TelemetryErrorType.Component) {
        telemetry.add(.errors, 1, ["error_type": type.rawValue, "component": component.rawValue])
    }

    /// A lifecycle failure no timed phase already counted (a missing forge, a token mint failure…).
    func recordLifecycleFailure(id: String, error: Error) {
        guard telemetry.isEnabled, !Task.isCancelled else { return }
        if jobTrace(for: id)?.claimErrorCount() ?? true {
            countError(TelemetryErrorType.classify(error, stage: .registration), component: .lifecycle)
        }
    }

    /// A runner took a job (or, for a short job that finished between polls, is known to have).
    /// Counts the pickup once per instance and opens the run span.
    func noteJobPickedUp(id: String, observed: Bool = true) {
        guard telemetry.isEnabled, let trace = jobTrace(for: id), trace.markRunStarted(observed: observed) else {
            return
        }
        telemetry.add(.jobsPickedUp, 1, metricAttributes(of: id))
    }

    /// The instance's job is done: completion count, run duration and trace end. A job that was never
    /// seen running (it started and finished between polls) still counts, with no run duration.
    func noteJobFinished(id: String, result: String = "completed") {
        guard telemetry.isEnabled, let trace = jobTrace(for: id) else { return }
        noteJobPickedUp(id: id, observed: false)
        let attributes = metricAttributes(of: id)
        if let seconds = trace.markRunFinished() {
            telemetry.record(.runDuration, seconds: seconds, attributes.merging(["result": result]) { $1 })
        }
        telemetry.add(.jobsCompleted, 1, attributes.merging(["result": result]) { $1 })
    }

    /// The forge's view of the job running on `id` (identifiers and provider timestamps), attached to
    /// the instance's trace; queue wait is recorded only when the forge gave both queue and start times.
    func noteJobCorrelation(vm id: String, _ correlation: JobCorrelation) {
        guard telemetry.isEnabled, let trace = jobTrace(for: id) else { return }
        noteJobPickedUp(id: id)
        if let wait = trace.attach(correlation) {
            telemetry.record(.queueWait, seconds: wait, metricAttributes(of: id))
        }
    }
}

// MARK: - Snapshot gauges

extension FleetEngine {
    private func series(_ value: Double, _ attributes: MetricAttributes = [:]) -> GaugeSeries {
        GaugeSeries(attributes: attributes, value: value)
    }

    /// Publishes the fleet's gauges once per reconcile pass: workers by pool, image, labels and
    /// state; fleet size and capacity; warm pool; runner, host and process resource use; forge
    /// budgets. A measurement the runtime or forge cannot supply is published as no series at
    /// all (unavailable), never as zero. VM ids are never attributes: runner usage is aggregated.
    func publishTelemetry() async {
        guard telemetry.isEnabled else { return }
        let status = await statusBox.get()
        let records = store.all

        // Workers.
        struct Key: Hashable { var pool: String, image: String, labels: String, state: String }
        var workers: [Key: Int] = [:]
        var warm: [Key: Int] = [:]
        for record in records {
            let labels = (poolLabels(for: record) ?? fleetLabels).sorted().joined(separator: ",")
            let key = Key(
                pool: record.runtime ?? RuntimeID.tart.rawValue, image: record.image ?? "default", labels: labels,
                state: record.phase.rawValue)
            workers[key, default: 0] += 1
            if record.phase == .warm { warm[key, default: 0] += 1 }
        }
        telemetry.publish(
            .workers,
            workers.map {
                series(
                    Double($0.value),
                    ["pool": $0.key.pool, "image": $0.key.image, "labels": $0.key.labels, "state": $0.key.state])
            })
        var warmByPool: [String: Int] = [:]
        for (key, count) in warm { warmByPool["\(key.pool)\u{1f}\(key.image)", default: 0] += count }
        telemetry.publish(
            .warmSize,
            warmByPool.map { entry in
                let parts = entry.key.split(separator: "\u{1f}", maxSplits: 1).map(String.init)
                return series(Double(entry.value), ["pool": parts[0], "image": parts.count > 1 ? parts[1] : "default"])
            })

        // Fleet size and state.
        let active = records.filter { $0.phase.isActive && $0.phase != .warm }.count
        telemetry.publish(.fleetDesired, [series(Double(status.desired))])
        telemetry.publish(.fleetActive, [series(Double(active))])
        telemetry.publish(
            .fleetCapacity,
            [series(Double(status.capacityCap), ["kind": "vm"]), series(Double(status.jobCapacity), ["kind": "job"])])
        telemetry.publish(.fleetPaused, [series(status.paused ? 1 : 0)])
        telemetry.publish(.fleetRunning, [series(status.running ? 1 : 0)])
        telemetry.publish(
            .jobsActive, [series(Double(records.reduce(0) { $0 + ($1.runningJobs?.count ?? ($1.job == nil ? 0 : 1)) }))]
        )

        // Forge budgets.
        var remaining: [GaugeSeries] = []
        var limits: [GaugeSeries] = []
        for forge in forgeState.withLock({ Array($0.byPlatform.values) }) {
            guard let limit = forge.rateLimit else { continue }
            let attributes = ["forge": forge.id.rawValue, "account": forge.account]
            remaining.append(series(Double(limit.remaining), attributes))
            limits.append(series(Double(limit.limit), attributes))
        }
        telemetry.publish(.rateLimitRemaining, remaining)
        telemetry.publish(.rateLimitLimit, limits)

        // Resource use: aggregated per pool and image, from the sampler (unavailable stays absent).
        let usage = await usageSampler.snapshot(for: records)
        struct Pool: Hashable { var pool: String, image: String }
        var cpu: [Pool: [Double]] = [:]
        var memory: [Pool: Int] = [:]
        var limitMB: [Pool: Int] = [:]
        for record in records {
            guard let sample = usage.byInstance[record.id] else { continue }
            let pool = Pool(pool: record.runtime ?? RuntimeID.tart.rawValue, image: record.image ?? "default")
            if let value = sample.cpuPercent { cpu[pool, default: []].append(value / 100) }
            if let value = sample.memoryUsedMB { memory[pool, default: 0] += value }
            if let value = sample.memoryLimitMB { limitMB[pool, default: 0] += value }
        }
        func attributes(_ pool: Pool) -> MetricAttributes { ["pool": pool.pool, "image": pool.image] }
        telemetry.publish(
            .runnerCPU, cpu.map { series($0.value.reduce(0, +) / Double($0.value.count), attributes($0.key)) })
        telemetry.publish(.runnerMemoryUsage, memory.map { series(Double($0.value) * 1_048_576, attributes($0.key)) })
        telemetry.publish(.runnerMemoryLimit, limitMB.map { series(Double($0.value) * 1_048_576, attributes($0.key)) })

        // Host and daemon process.
        if let host = usage.host {
            telemetry.publish(.hostCPU, host.cpuPercent.map { [series($0 / 100)] } ?? [])
            telemetry.publish(.hostMemoryUsage, [series(host.memoryUsedGB * 1_073_741_824)])
            telemetry.publish(.hostMemoryLimit, [series(host.memoryTotalGB * 1_073_741_824)])
        }
        telemetry.publish(.hostDiskFree, [series(Double(hostProbe().freeDiskGB) * 1_073_741_824)])
        let process = processUsage.sample()
        telemetry.publish(.processCPU, process.cpuUtilization.map { [series($0)] } ?? [])
        telemetry.publish(.processMemory, process.residentBytes.map { [series(Double($0))] } ?? [])
    }

    /// Per-forge queue depth and the age of the oldest queued job, from one pass's demand read. The age
    /// is reported only for jobs whose forge supplied a queue timestamp; with none it is absent.
    func publishQueueTelemetry(byForge: [String: Int], oldestEnqueuedAt: Date?, now: Date = Date()) {
        guard telemetry.isEnabled else { return }
        telemetry.publish(
            .queueDepth, byForge.map { series(Double($0.value), ["account": $0.key]) })
        telemetry.publish(
            .queueAgeMax, oldestEnqueuedAt.map { [series(max(0, now.timeIntervalSince($0)))] } ?? [])
    }

    /// Healing: awaiting-approval count as a gauge, finished fixes as a counter (once per event).
    func recordHealingTelemetry(_ snapshot: HealingSnapshot) {
        guard telemetry.isEnabled else { return }
        telemetry.publish(.healingPending, [series(Double(snapshot.events.filter { $0.outcome == .pending }.count))])
        let finished = snapshot.events.filter { $0.outcome == .succeeded || $0.outcome == .failed }
        let fresh = healingCounted.withLock { counted -> [HealingEvent] in
            // The journal outlives the process: what had already finished when this engine first published is
            // history, not an action taken now, so it is remembered without being counted.
            guard counted.baselined else {
                counted.baselined = true
                counted.seen.formUnion(finished.map(\.id))
                return []
            }
            return finished.filter { counted.seen.insert($0.id).inserted }
        }
        for event in fresh { telemetry.add(.healingActions, 1, ["result": event.outcome.rawValue]) }
    }
}
