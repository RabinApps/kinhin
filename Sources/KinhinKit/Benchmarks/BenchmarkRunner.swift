import Foundation

/// Orchestrates a benchmark run: preflight, fleet pause/drain/resume, scratch
/// setup, the suites, the report, and a cleanup that always runs. It talks to
/// no forge and never touches the Keychain, so no credential can reach a
/// bench instance or a report.
public actor BenchmarkRunner {
    /// What a runtime offers this run.
    struct RuntimeStatus: Sendable, Equatable {
        var reason: String?
        var isReady: Bool { reason == nil }
    }

    public nonisolated let runID: String
    private let env: BenchmarkEnvironment
    private let sink: BenchmarkProgressSink
    private let tracker = InstanceTracker()
    private var shared: [RuntimeID: BenchmarkInstance] = [:]

    public init(
        environment: BenchmarkEnvironment, progress: BenchmarkProgressSink = BenchmarkProgressSink(),
        runID: String? = nil
    ) {
        self.env = environment
        self.sink = progress
        self.runID = runID ?? Self.newRunID()
    }

    /// `bench-20261008-142530-a3f1`; the last four characters name the run's instances.
    public static func newRunID(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(format: "%04x", Int.random(in: 0...0xFFFF))
        return "bench-\(formatter.string(from: now))-\(suffix)"
    }

    private var runShort: String { String(runID.suffix(4)) }

    // MARK: - Fleet

    /// The fleet's load, so a caller can ask before pausing it. Nil when there is no fleet to pause.
    public func fleetImpact() async -> BenchmarkFleetImpact? {
        guard let fleet = env.fleet else { return nil }
        do {
            return try await fleet.impact()
        } catch is CancellationError {
            return nil
        } catch {
            Log.warn("bench", "could not read the fleet's load: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Run

    public func run(_ options: BenchmarkOptions) async throws -> BenchmarkReport {
        try options.validate()
        let started = Date()
        sink.set(phase: "preflight", suite: .some(nil), runtime: .some(nil), step: .some(nil))
        let profile = BenchmarkProfile.make(options.intensity, iterations: options.iterations)

        // A video-only run builds in a container on the host and touches no VM, so it leaves the fleet alone.
        let usesFleet = options.suites.contains { $0 != .video }
        if usesFleet, let impact = await fleetImpact(), impact.active > 0, !options.confirmed {
            throw BenchmarkError.fleetBusy(active: impact.active, busy: impact.busy)
        }
        let status = await availability(of: runtimesToProbe(options), includeHost: options.includeHost)
        let plan = try RunPlan.make(options: options, config: env.config, status: status)
        try checkDisk(options, plan: plan)
        await sweepStrays(status: status)

        let scratch = BenchmarkScratch(benchRoot: env.root, runID: runID)
        let hold = usesFleet ? env.fleet.map { FleetHold(fleet: $0) } : nil
        var suites: [BenchmarkSuiteResult] = []
        var failure: Error?
        do {
            if let hold {
                sink.set(phase: "pausing the fleet")
                try await hold.hold(
                    force: options.force, drainSeconds: env.drainSeconds, poll: env.drainPoll)
            }
            try scratch.create()
            sink.set(phase: "running")
            let context = BenchmarkContext(
                env: env, options: options, profile: profile, scratch: scratch, sink: sink, tracker: tracker,
                runShort: runShort)
            suites = try await execute(context, plan: plan, status: status)
        } catch {
            failure = error
        }

        await cleanUp(scratch: scratch, keep: options.keep, hold: hold)
        if let failure { throw failure }

        sink.set(phase: "writing the report", suite: .some(nil), runtime: .some(nil), step: .some(nil))
        let report = makeReport(options, started: started, suites: suites, status: status)
        let store = BenchmarkReportStore(directory: env.root)
        do {
            let url = try store.write(report)
            Log.info("bench", "report written to \(url.path)")
        } catch {
            Log.error("bench", "could not write the report: \(error.localizedDescription)")
            throw error
        }
        sink.set(phase: "finished")
        return report
    }

    // MARK: - Cleanup

    /// Removes every instance, the scratch directory and the fleet pause. Runs after success, failure and
    /// cancellation alike, and never throws.
    private func cleanUp(scratch: BenchmarkScratch, keep: Bool, hold: FleetHold?) async {
        sink.set(phase: "cleaning up", suite: .some(nil), runtime: .some(nil), step: .some(nil))
        shared = [:]
        let tracker = self.tracker
        await bestEffortAsync("bench", "cleaning up") {
            try await withoutCancellation {
                await tracker.releaseAll()
                if !keep { scratch.remove() }
                await hold?.resume()
            }
        }
    }

    /// Instances left by a crashed earlier run (`kinhin-bench-*`), removed before this one starts.
    private func sweepStrays(status: [RuntimeID: RuntimeStatus]) async {
        for id in [RuntimeID.tart, .appleContainer, .docker] {
            // A runtime that is not installed or not running has nothing to sweep (and nothing to ask).
            guard status[id]?.isReady == true || (id == .tart && status[id]?.reason?.hasPrefix("image") == true),
                let runtime = env.makeRuntime(id, nil)
            else { continue }
            let names: [String]
            do {
                names = try await runtime.existingInstanceIDs()
            } catch is CancellationError {
                return
            } catch {
                continue
            }
            for name in names where name.hasPrefix(BenchmarkNaming.instancePrefix) {
                Log.warn("bench", "removing leftover benchmark instance \(name)")
                await bestEffortAsync(name, "removing leftover benchmark instance") {
                    try await runtime.teardown(id: name)
                }
            }
        }
    }

    // MARK: - Preflight

    /// The runtimes worth probing: every one for an open-ended run, only the named ones (plus the macOS VM the
    /// Xcode suite always needs) when the caller chose.
    private func runtimesToProbe(_ options: BenchmarkOptions) -> [RuntimeID] {
        guard var ids = options.runtimes else { return RuntimeID.allCases }
        if options.suites.contains(.xcode), !ids.contains(.tart) { ids.append(.tart) }
        return ids
    }

    func availability(of ids: [RuntimeID], includeHost: Bool) async -> [RuntimeID: RuntimeStatus] {
        var status: [RuntimeID: RuntimeStatus] = [:]
        for id in ids {
            status[id] = await probe(id, includeHost: includeHost)
        }
        return status
    }

    private func probe(_ id: RuntimeID, includeHost: Bool) async -> RuntimeStatus {
        guard let runtime = env.makeRuntime(id, nil) else {
            return RuntimeStatus(reason: "not supported on this build")
        }
        if id == .host, !includeHost {
            return RuntimeStatus(reason: "needs --include-host (host jobs run unisolated on this Mac)")
        }
        switch await env.health(id, runtime) {
        case .ready: break
        case .missing(let tool, let fix): return RuntimeStatus(reason: "\(tool) is not installed (\(fix))")
        case .broken(let why): return RuntimeStatus(reason: why)
        }
        guard id != .host else { return RuntimeStatus() }
        let image = env.image(for: id)
        do {
            let names = try await env.localImages(id)
            guard BenchmarkContext.imagePresent(image, in: names) else {
                return RuntimeStatus(
                    reason: "image '\(image)' is not on this Mac — run `kinhin image prepare` first")
            }
        } catch is CancellationError {
            return RuntimeStatus(reason: "cancelled")
        } catch {
            return RuntimeStatus(reason: "could not list images: \(error.localizedDescription)")
        }
        return RuntimeStatus()
    }

    private func checkDisk(_ options: BenchmarkOptions, plan: RunPlan) throws {
        let usesTart = plan.usesRuntime(.tart)
        var needed =
            usesTart
            ? ResourceProbe.effectiveDiskPerVMGB(diskGB: env.config.diskGB, runtime: .tart)
            : ResourceProbe.effectiveDiskPerVMGB(diskGB: env.config.diskGB, runtime: .docker)
        needed += 1  // host scratch
        if options.suites.contains(.large) {
            needed += BenchmarkProfile.make(options.intensity, iterations: options.iterations).blobMB / 1024 + 1
        }
        let free = env.hostResources().freeDiskGB
        if free < needed { throw BenchmarkError.insufficientDisk(neededGB: needed, freeGB: free) }
    }

    // MARK: - Suites

    private func execute(_ ctx: BenchmarkContext, plan: RunPlan, status: [RuntimeID: RuntimeStatus]) async throws
        -> [BenchmarkSuiteResult]
    {
        var results: [BenchmarkSuiteResult] = []
        func record(_ batch: [BenchmarkSuiteResult]) {
            for result in batch {
                sink.complete(result)
                results.append(result)
            }
        }
        for suite in BenchmarkOptions.Suite.allCases where ctx.options.suites.contains(suite) {
            try Task.checkCancellation()
            let name = suite.rawValue
            for id in plan.runtimes(for: suite) {
                try Task.checkCancellation()
                sink.set(suite: name, runtime: id.rawValue, step: .some(nil))
                let reason = status[id]?.reason
                switch suite {
                case .boot:
                    record(try await BootBenchmark.run(ctx, runtime: id, unavailable: reason))
                case .video:
                    // The video image is not the bench image, so an image-missing reason does not apply: the
                    // suite checks its own runtime and image and skips with its own reason.
                    if let reason, !reason.hasPrefix("image '") {
                        record([.skipped(name, runtime: id, reason: reason)])
                    } else {
                        record([try await VideoBenchmark.run(ctx, runtime: id)])
                    }
                case .toolchains:
                    if let reason {
                        record([.skipped(name, runtime: id, reason: reason)])
                    } else {
                        record([try await ToolchainBenchmark.run(ctx, runtime: id, ids: plan.toolchainIDs)])
                    }
                case .casual, .large, .xcode:
                    if let reason {
                        record([.skipped(name, runtime: id, reason: reason)])
                        continue
                    }
                    do {
                        let instance = try await sharedInstance(id, ctx)
                        switch suite {
                        case .casual: record([try await WorkflowBenchmark.casual(ctx, on: instance)])
                        case .large: record([try await WorkflowBenchmark.large(ctx, on: instance)])
                        default: record([try await XcodeBenchmark.run(ctx, on: instance)])
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                        record([BenchmarkSuiteResult(name: name, runtime: id.rawValue, status: .failed, error: message)]
                        )
                    }
                }
            }
        }
        return results
    }

    /// The one instance per runtime the Casual, Xcode and Large suites share.
    private func sharedInstance(_ id: RuntimeID, _ ctx: BenchmarkContext) async throws -> BenchmarkInstance {
        if let existing = shared[id] { return existing }
        let instance = try await ctx.acquire(id)
        shared[id] = instance
        return instance
    }

    // MARK: - Report

    private func makeReport(
        _ options: BenchmarkOptions, started: Date, suites: [BenchmarkSuiteResult], status: [RuntimeID: RuntimeStatus]
    ) -> BenchmarkReport {
        let host = env.hostResources()
        let info = env.hostInfo()
        let config = env.config
        return BenchmarkReport(
            runID: runID, startedAt: started, finishedAt: Date(), kinhinVersion: kinhinVersion.current,
            host: .init(
                chip: info.chip, cores: host.logicalCores, memoryGB: host.memoryGB, freeDiskGB: host.freeDiskGB,
                arm64: host.arm64, os: info.os),
            setup: .init(
                image: config.image, containerImage: config.container?.image, dockerImage: config.docker?.image,
                runtimes: RuntimeID.allCases.filter { status[$0]?.isReady == true }.map(\.rawValue),
                vmCPU: config.vm.cpuCount, vmMemoryGB: config.vm.memoryGB, softnet: config.tartSoftnet == true),
            intensity: options.intensity.rawValue, suites: suites)
    }
}

// MARK: - Which runtimes each suite uses

/// The runtimes a run measures per suite, decided once at preflight.
struct RunPlan: Sendable {
    let byRuntime: [BenchmarkOptions.Suite: [RuntimeID]]
    let toolchainIDs: [String]?

    func runtimes(for suite: BenchmarkOptions.Suite) -> [RuntimeID] { byRuntime[suite] ?? [] }

    func usesRuntime(_ id: RuntimeID) -> Bool { byRuntime.values.contains { $0.contains(id) } }

    static func make(
        options: BenchmarkOptions, config: KinhinConfig, status: [RuntimeID: BenchmarkRunner.RuntimeStatus]
    ) throws -> RunPlan {
        let explicit = options.runtimes
        // A runtime the caller named must be usable: silently skipping it would hide the mistake.
        for id in explicit ?? [] {
            if let reason = status[id]?.reason {
                if reason.hasPrefix("image '") {
                    throw BenchmarkError.imageMissing(runtime: id, image: imageName(reason))
                }
                throw BenchmarkError.runtimeUnavailable(runtime: id, why: reason)
            }
        }
        func ready(_ id: RuntimeID) -> Bool { status[id]?.isReady == true }
        let primary = Capacity.primaryRuntime(of: config)
        let workloadDefault: [RuntimeID] = {
            if ready(primary) { return [primary] }
            return [RuntimeID.tart, .appleContainer, .docker].first(where: ready).map { [$0] } ?? [primary]
        }()
        var map: [BenchmarkOptions.Suite: [RuntimeID]] = [:]
        for suite in options.suites {
            switch suite {
            case .boot:
                // Every runtime gets a row; host reads "skipped" until the caller consents.
                map[suite] = explicit ?? RuntimeID.allCases
            case .casual, .large:
                map[suite] = explicit ?? workloadDefault
            case .xcode:
                map[suite] = [.tart]
            case .video:
                // Builds run in a container runtime: the named one(s), else the first that works.
                let containers = [RuntimeID.appleContainer, .docker]
                if let explicit {
                    map[suite] = explicit.filter { containers.contains($0) }
                } else {
                    let usable = containers.first { status[$0]?.reason.map { $0.hasPrefix("image '") } ?? true }
                    map[suite] = [usable ?? .appleContainer]
                }
            case .toolchains:
                if let explicit {
                    map[suite] = explicit.filter { $0 != .host }
                } else {
                    let linux = [RuntimeID.appleContainer, .docker].first(where: ready)
                    map[suite] = [RuntimeID.tart] + [linux].compactMap { $0 }
                }
            }
        }
        if map.values.allSatisfy({ $0.allSatisfy { !ready($0) } }), options.runtimes == nil,
            !(map[.boot] ?? []).isEmpty, options.suites != [.boot]
        {
            throw BenchmarkError.nothingToRun("no runtime is ready on this Mac (run `kinhin doctor`)")
        }
        let ids = options.allToolchains || options.toolchains.isEmpty ? nil : options.toolchains
        return RunPlan(byRuntime: map, toolchainIDs: ids)
    }

    private static func imageName(_ reason: String) -> String {
        let parts = reason.split(separator: "'")
        return parts.count > 1 ? String(parts[1]) : reason
    }
}
