import Foundation

/// Which healing events `kinhin.healing.actions` has counted, and whether the journal's history was skipped yet.
struct HealingCounted {
    var seen: Set<String> = []
    var baselined = false
}

// FleetEngine — telemetry recording: per-instance traces, phase timings, job pickup and completion,
// and error counts. Every method is a no-op while the handle is the no-op one.
extension FleetEngine {
    /// The sorted runner labels an instance advertises, as the `kinhin.runner.labels` value: the pool's, else the
    /// fleet's. They come from the config, so the set is as small as the pools are.
    func runnerLabelsValue(of record: VMRecord?) -> String {
        (record.flatMap { poolLabels(for: $0) } ?? fleetLabels).sorted().joined(separator: ",")
    }

    /// The bounded metric attributes of an instance: pool (runtime), image, forge and runner labels.
    func metricAttributes(of id: String) -> MetricAttributes {
        let record = store.all.first { $0.id == id }
        return [
            Metric.Attr.pool: record?.runtime ?? RuntimeID.tart.rawValue, Metric.Attr.image: record?.image ?? "default",
            Metric.Attr.forge: record?.platform ?? ForgeID.github.rawValue,
            Metric.Attr.labels: runnerLabelsValue(of: record),
        ]
    }

    func makeJobTrace(id: String) -> JobTrace {
        let attributes = metricAttributes(of: id)
        let record = store.all.first { $0.id == id }
        return JobTrace(
            telemetry: telemetry, vm: id, pool: attributes[Metric.Attr.pool] ?? "tart",
            image: attributes[Metric.Attr.image] ?? "default", forge: attributes[Metric.Attr.forge] ?? "github",
            labels: record.flatMap { poolLabels(for: $0) })
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
    /// failure counts once in `cicd.system.errors`, classified by the phase it happened in.
    func timed<T>(_ phase: Metric.Phase, id: String, _ body: () async throws -> T) async throws -> T {
        guard telemetry.isEnabled else { return try await body() }
        let trace = jobTrace(for: id)
        trace?.begin(phase)
        let start = ContinuousClock.now
        do {
            let value = try await body()
            let seconds = (ContinuousClock.now - start) / .seconds(1)
            if phase == .teardown {
                telemetry.record(.teardownDuration, seconds: seconds, metricAttributes(of: id))
            } else {
                telemetry.record(
                    .phaseDuration, seconds: seconds,
                    metricAttributes(of: id).merging([Metric.Attr.phase: phase.metricName]) { $1 })
            }
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

    /// The observer a project-image builder reports finished bakes through: a duration sample and a
    /// success or failure count, labelled by the derived image only.
    /// Always returned: the handle is the no-op until telemetry is switched on, and a hot reload can do that
    /// without rebuilding the engine, so the check belongs to `add` and `record`, not to construction.
    static func bakeRecorder(_ telemetry: Telemetry) -> ProjectImageBuilder.BakeObserver? {
        return { image, seconds, succeeded in
            let attributes = [Metric.Attr.image: image, Metric.Attr.outcome: succeeded ? "success" : "failure"]
            telemetry.record(.imageBakeDuration, seconds: seconds, attributes)
            telemetry.add(.imageBakes, 1, attributes)
        }
    }

    /// One real cache sweep: counts it and remembers the size it measured for the gauge.
    func noteCacheSweep(report: ToolchainPruneReport?, totalBytes: Int64?) {
        // A cache that is not there (or could not be walked) has no size: absent, not zero.
        toolchainCacheBytes.withLock { $0 = totalBytes }
        // A sweep that skipped (no cache directory) did not run, so it is not counted.
        guard let report, !report.dryRun, report.remainingBytes != nil else { return }
        telemetry.add(.cachePrunes, 1, [Metric.Attr.outcome: report.failedCount > 0 ? "failure" : "success"])
    }

    func countError(_ type: TelemetryErrorType, component: TelemetryErrorType.Component) {
        telemetry.add(
            .errors, 1, [Metric.Attr.errorType: type.rawValue, Metric.Attr.component: component.rawValue])
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
        // The forge names the job (id, workflow, queue time) only on the next running-jobs read, which a short job can
        // outrun: ask for that read now, once per job, so the verdict and the trace carry the job's identity.
        if observed { pollSoon() }
    }

    /// The opt-in per-job dimensions (`telemetry.job_attributes`), where the forge supplied the value.
    private func jobDimensions(_ correlation: JobCorrelation?) -> MetricAttributes {
        var out: MetricAttributes = [:]
        let wanted = telemetry.jobAttributes
        if wanted.contains(.repository), let value = correlation?.repository { out[Metric.Attr.repository] = value }
        if wanted.contains(.workflow), let value = correlation?.workflow { out[Metric.Attr.workflow] = value }
        return out
    }

    /// What the forge says the finished job did. A job's state flips to completed a moment after its runner
    /// leaves, so an unfinished answer is retried briefly. Nil when the forge cannot say (kinhin then reports
    /// the result as unknown rather than guessing).
    private func fetchJobOutcome(id: String, trace: JobTrace) async -> JobOutcome? {
        guard let correlation = trace.correlation, correlation.jobID != nil else { return nil }
        let platform = store.all.first { $0.id == id }?.platform ?? ForgeID.github.rawValue
        guard let forge = forgeState.withLock({ $0.byPlatform[platform] }) else { return nil }
        for attempt in 0..<4 {
            if Task.isCancelled { return nil }
            do {
                if let outcome = try await forge.jobOutcome(for: correlation),
                    outcome.result != nil
                        || outcome.completedAt != nil
                {
                    return outcome
                }
            } catch {
                Log.debug(id, "job outcome unavailable: \(error.localizedDescription)")
                return nil
            }
            if attempt < 3 { try? await Task.sleep(for: .seconds(1)) }  // cancelled: the next loop turn returns
        }
        return nil
    }

    /// The instance's job is done: completion count, run duration, the forge's verdict and step spans.
    /// A job that was never seen running (it started and finished between polls) still counts; with the
    /// forge's own times it still gets a duration, without them it gets none.
    func noteJobFinished(id: String) async {
        guard telemetry.isEnabled, let trace = jobTrace(for: id) else { return }
        noteJobPickedUp(id: id, observed: false)
        let outcome = await fetchJobOutcome(id: id, trace: trace)
        let result = outcome?.result?.rawValue ?? "unknown"
        let observed = trace.markRunFinished(at: outcome?.completedAt)
        var seconds = observed
        if let start = outcome?.startedAt, let end = outcome?.completedAt, end >= start {
            seconds = end.timeIntervalSince(start)
        }
        var attributes = metricAttributes(of: id).merging(jobDimensions(trace.correlation)) { $1 }
        attributes[Metric.Attr.result] = result
        if let seconds { telemetry.record(.runDuration, seconds: seconds, attributes) }
        telemetry.add(.jobsCompleted, 1, attributes)
        trace.setResult(result)
        if let outcome { trace.addProviderSteps(outcome.steps) }
    }

    /// The forge's view of the job running on `id` (identifiers and provider timestamps), attached to
    /// the instance's trace; queue wait is recorded only when the forge gave both queue and start times.
    func noteJobCorrelation(vm id: String, _ correlation: JobCorrelation) {
        guard telemetry.isEnabled, let trace = jobTrace(for: id) else { return }
        noteJobPickedUp(id: id)
        if let wait = trace.attach(correlation) {
            let attributes = metricAttributes(of: id).merging(jobDimensions(correlation)) { $1 }
            telemetry.record(.queueWait, seconds: wait, attributes)
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
        // Telemetry switched on by a reload: the daily sweep that measures the cache starts now.
        if cachePruneTask == nil && runState.withLock({ $0.running }) { startCachePruneSweepIfNeeded() }
        let status = await statusBox.get()
        let records = store.all

        // Workers.
        struct Key: Hashable { var pool: String, image: String, labels: String, state: String }
        var workers: [Key: Int] = [:]
        var warm: [Key: Int] = [:]
        for record in records {
            let labels = runnerLabelsValue(of: record)
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
                    [
                        Metric.Attr.pool: $0.key.pool, Metric.Attr.image: $0.key.image,
                        Metric.Attr.labels: $0.key.labels, Metric.Attr.state: $0.key.state,
                    ])
            })
        var warmByPool: [String: Int] = [:]
        for (key, count) in warm { warmByPool["\(key.pool)\u{1f}\(key.image)", default: 0] += count }
        telemetry.publish(
            .warmSize,
            warmByPool.map { entry in
                let parts = entry.key.split(separator: "\u{1f}", maxSplits: 1).map(String.init)
                return series(
                    Double(entry.value),
                    [Metric.Attr.pool: parts[0], Metric.Attr.image: parts.count > 1 ? parts[1] : "default"])
            })

        // Fleet size and state.
        let active = records.filter { $0.phase.isActive && $0.phase != .warm }.count
        telemetry.publish(.fleetDesired, [series(Double(status.desired))])
        telemetry.publish(.fleetActive, [series(Double(active))])
        telemetry.publish(
            .poolCapacity,
            // A single-pool fleet has no per-runtime caps: its one pool is capped by the fleet cap.
            (capsByRuntime.isEmpty ? [Capacity.primaryRuntime(of: config): status.capacityCap] : capsByRuntime)
                .map { series(Double($0.value), [Metric.Attr.pool: $0.key.rawValue]) })
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
            let attributes = [Metric.Attr.forge: forge.id.rawValue, Metric.Attr.account: forge.account]
            remaining.append(series(Double(limit.remaining), attributes))
            limits.append(series(Double(limit.limit), attributes))
        }
        telemetry.publish(.rateLimitRemaining, remaining)
        telemetry.publish(.rateLimitLimit, limits)

        // Resource use: aggregated per pool and image, from the sampler (unavailable stays absent).
        let usage = await usageSampler.snapshot(for: records)
        struct Pool: Hashable { var pool: String, image: String, labels: String }
        var cpu: [Pool: [Double]] = [:]
        var memory: [Pool: Int] = [:]
        var limitMB: [Pool: Int] = [:]
        var diskGB: [Pool: Int] = [:]
        for record in records {
            guard let sample = usage.byInstance[record.id] else { continue }
            let pool = Pool(
                pool: record.runtime ?? RuntimeID.tart.rawValue, image: record.image ?? "default",
                labels: runnerLabelsValue(of: record))
            if let value = sample.cpuPercent { cpu[pool, default: []].append(value / 100) }
            if let value = sample.memoryUsedMB { memory[pool, default: 0] += value }
            if let value = sample.memoryLimitMB { limitMB[pool, default: 0] += value }
            if let value = sample.diskUsedGB { diskGB[pool, default: 0] += value }
        }
        func attributes(_ pool: Pool) -> MetricAttributes {
            [Metric.Attr.pool: pool.pool, Metric.Attr.image: pool.image, Metric.Attr.labels: pool.labels]
        }
        telemetry.publish(
            .runnerCPU, cpu.map { series($0.value.reduce(0, +) / Double($0.value.count), attributes($0.key)) })
        telemetry.publish(.runnerMemoryUsage, memory.map { series(Double($0.value) * 1_048_576, attributes($0.key)) })
        telemetry.publish(.runnerMemoryLimit, limitMB.map { series(Double($0.value) * 1_048_576, attributes($0.key)) })
        // Disk the runners occupy on the host (tart reports whole GB, decimal), summed per pool and image.
        telemetry.publish(.runnerDiskUsage, diskGB.map { series(Double($0.value) * 1_000_000_000, attributes($0.key)) })
        telemetry.publish(
            .cacheSize,
            toolchainCacheBytes.withLock { $0 }.map { [series(Double($0), [Metric.Attr.cache: "toolchain"])] } ?? [])

        publishServiceHealth()

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
    func publishQueueTelemetry(
        byForge: [String: Int], byPool: [RuntimeID: Int] = [:], oldestEnqueuedAt: Date?, now: Date = Date()
    ) {
        guard telemetry.isEnabled else { return }
        telemetry.publish(.queueDepth, byForge.map { series(Double($0.value), [Metric.Attr.account: $0.key]) })
        telemetry.publish(
            .queueDepthByPool, byPool.map { series(Double($0.value), [Metric.Attr.pool: $0.key.rawValue]) })
        telemetry.publish(
            .queueAge, oldestEnqueuedAt.map { [series(max(0, now.timeIntervalSince($0)))] } ?? [])
    }

    /// One completed reconcile pass: its duration and when it finished (a stuck loop shows as a growing gap).
    func recordReconcilePass(seconds: Double, now: Date = Date()) {
        lastReconcileSuccess.withLock { $0 = now }
        telemetry.record(.reconcileDuration, seconds: seconds)
    }

    /// Daemon identity and health gauges, and spawn holds, published with the rest each pass.
    func publishServiceHealth(now: Date = Date()) {
        telemetry.publish(.buildInfo, [series(1, [Metric.Attr.version: kinhinVersion.current])])
        telemetry.publish(.daemonUptime, [series(max(0, now.timeIntervalSince(startedAt)))])
        telemetry.publish(
            .reconcileLastSuccess,
            lastReconcileSuccess.withLock { $0 }.map { [series($0.timeIntervalSince1970)] } ?? [])
        // What is holding new instances back: a runtime in spawn backoff, or disk pressure (value 1 each).
        var holds: [GaugeSeries] = spawnBackoff.withLock { $0.blocked(now: now) }.map {
            series(1, [Metric.Attr.pool: $0.rawValue, Metric.Attr.holdReason: "backoff"])
        }
        if diskHold.withLock({ $0 }) { holds.append(series(1, [Metric.Attr.holdReason: "disk_pressure"])) }
        telemetry.publish(.spawnHeld, holds)
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
        for event in fresh { telemetry.add(.healingActions, 1, [Metric.Attr.healingResult: event.outcome.rawValue]) }
    }
}
