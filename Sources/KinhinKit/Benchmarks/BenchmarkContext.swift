import Foundation

/// What a suite needs to run: the environment, the sizing, the progress sink
/// and the instance tracker. A value type: suites pass it around freely.
struct BenchmarkContext: Sendable {
    let env: BenchmarkEnvironment
    let options: BenchmarkOptions
    let profile: BenchmarkProfile
    let scratch: BenchmarkScratch
    let sink: BenchmarkProgressSink
    let tracker: InstanceTracker
    /// Four hex characters naming this run's instances.
    let runShort: String

    var bootTimeout: TimeInterval { TimeInterval(env.config.vmBootTimeout) }

    func route(for runtime: RuntimeID) -> RepoRoute {
        RepoRoute(
            repo: "kinhin/bench", image: env.image(for: runtime), ephemeral: true,
            bootTimeout: env.config.vmBootTimeout)
    }

    // MARK: - Timing

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// Times `body` on the monotonic clock.
    static func measure<T>(_ body: () async throws -> T) async rethrows -> (value: T, ms: Double) {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await body()
        return (value, milliseconds(clock.now - start))
    }

    // MARK: - Instances

    /// Provisions an instance of `runtime`, tracked from before its first call so a failure cannot leak it,
    /// then waits for it and learns its guest OS.
    func acquire(_ runtime: RuntimeID, platform: LinuxPlatform? = nil) async throws -> BenchmarkInstance {
        do {
            return try await acquireOnce(runtime, platform: platform)
        } catch is CancellationError {
            throw CancellationError()
        } catch  where runtime == .tart {
            // A VM now and then never gets a network lease (seen under softnet): one fresh VM is a better answer
            // than a failed suite. The failed one is removed by the tracker at the end of the run.
            Log.warn(
                "bench",
                "a \(runtime.rawValue) guest did not come up (\(error.localizedDescription)); trying a fresh one")
            return try await acquireOnce(runtime, platform: platform)
        }
    }

    private func acquireOnce(_ runtime: RuntimeID, platform: LinuxPlatform?) async throws -> BenchmarkInstance {
        guard let implementation = env.makeRuntime(runtime, platform) else {
            throw BenchmarkError.runtimeUnavailable(runtime: runtime, why: "not supported on this build")
        }
        let name = BenchmarkNaming.instanceName(runShort: runShort, index: tracker.nextIndex())
        tracker.track(name: name, runtime: implementation)
        sink.set(step: "boot \(runtime.rawValue)")
        try await implementation.provision(id: name, route: route(for: runtime))
        let ip = try await implementation.awaitReady(id: name, timeout: bootTimeout)
        let guest = try await detectGuest(runtime, implementation, name: name, ip: ip)
        return BenchmarkInstance(
            runtimeID: runtime, runtime: implementation, name: name, ip: ip, platform: guest.toolchainPlatform,
            benchDirectory: Self.benchDirectory(for: implementation, name: name), isolatesStdin: env.isolatesStdin)
    }

    private func detectGuest(_ id: RuntimeID, _ runtime: any Runtime, name: String, ip: String?) async throws
        -> GuestOS
    {
        switch id {
        case .appleContainer, .docker: return .linux
        case .host: return .macOS
        case .tart:
            let result = try await runtime.execRegistration(name, ip: ip, GuestOS.probeScript, timeout: 120)
            guard result.succeeded, let guest = GuestOS.parse(unameOutput: result.stdout) else {
                throw BenchmarkError.stepFailed(step: "guest detection", detail: result.failureExcerpt)
            }
            return guest
        }
    }

    static func benchDirectory(for runtime: any Runtime, name: String) -> String {
        if let host = runtime as? HostRuntime {
            return "BENCH=\(BenchmarkScripts.quote(host.workDirectory(for: name).path))"
        }
        return #"BENCH="$HOME/kinhin-bench""#
    }

    // MARK: - Steps

    /// Runs `script` in the instance and times it host-side. `setup` runs first, untimed. A script that exits
    /// 77 reports a skipped step; any other failure throws.
    func step(
        _ instance: BenchmarkInstance, _ name: String, setup: String? = nil, script: String, bytes: Int? = nil,
        timeout: TimeInterval = 600
    ) async throws -> BenchmarkStep {
        sink.set(step: name)
        if let setup {
            let prepared = try await instance.exec(instance.prelude + "\n" + setup, timeout: timeout)
            guard prepared.succeeded else {
                throw BenchmarkError.stepFailed(step: "\(name) (setup)", detail: Self.detail(of: prepared))
            }
        }
        let timed = try await Self.measure {
            try await instance.exec(instance.prelude + "\n" + script, timeout: timeout)
        }
        let result = timed.value
        if result.exitCode == BenchmarkScripts.skipExitCode {
            return BenchmarkStep(name: name, durationMs: 0, note: Self.lastLine(result.stdout), skipped: true)
        }
        guard result.succeeded else {
            throw BenchmarkError.stepFailed(step: name, detail: Self.detail(of: result))
        }
        let moved = Self.reportedBytes(result.stdout) ?? bytes
        let throughput = moved.flatMap { timed.ms > 0 ? Double($0) / (timed.ms / 1000) : nil }
        return BenchmarkStep(name: name, durationMs: timed.ms, throughput: throughput)
    }

    /// Runs a script untimed (setup, probes). Returns the raw result.
    func run(_ instance: BenchmarkInstance, _ script: String, timeout: TimeInterval = 600) async throws -> ShellResult {
        try await instance.exec(instance.prelude + "\n" + script, timeout: timeout)
    }

    static func detail(of result: ShellResult) -> String {
        let excerpt = result.failureExcerpt
        guard result.stderr.isEmpty else { return excerpt }
        let tail = result.stdout.split(whereSeparator: \.isNewline).suffix(8).joined(separator: "\n")
        return tail.isEmpty ? excerpt : String(tail.suffix(700))
    }

    static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func reportedBytes(_ stdout: String) -> Int? {
        for line in stdout.split(whereSeparator: \.isNewline).reversed()
        where line.hasPrefix(BenchmarkScripts.bytesMarker) {
            return Int(line.dropFirst(BenchmarkScripts.bytesMarker.count))
        }
        return nil
    }

    // MARK: - Suite wrapper

    /// Runs a suite body, turning a failure into a `failed` result (cancellation still propagates).
    func suite(
        _ name: String, runtime: RuntimeID, platform: String?, notes: [String] = [],
        _ body: (inout [BenchmarkStep]) async throws -> Void
    ) async throws -> BenchmarkSuiteResult {
        sink.set(suite: name, runtime: runtime.rawValue, step: nil)
        var steps: [BenchmarkStep] = []
        do {
            try await body(&steps)
            return BenchmarkSuiteResult(
                name: name, runtime: runtime.rawValue, platform: platform, status: .ran, notes: notes, steps: steps)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.warn("bench", "\(name) on \(runtime.rawValue) failed: \(message)")
            return BenchmarkSuiteResult(
                name: name, runtime: runtime.rawValue, platform: platform, status: .failed, error: message,
                notes: notes, steps: steps)
        }
    }

    /// Whether `image` is among the runtime's local image names (`ubuntu`, `ubuntu:latest`, `repo/ubuntu:tag`).
    static func imagePresent(_ image: String, in names: [String]) -> Bool {
        names.contains { $0 == image || $0 == image + ":latest" || $0.hasPrefix(image + ":") }
    }
}
