import Foundation

/// The Boot suite: how long each runtime takes from nothing to a guest that
/// runs a command, so one report answers "which runtime boots fastest here".
/// Tart is timed phase by phase exactly as `FleetLifecycle` walks them.
enum BootBenchmark {
    /// One row per runtime. `unavailable` holds the reason a runtime cannot run on this Mac.
    static func run(_ ctx: BenchmarkContext, runtime id: RuntimeID, unavailable: String?) async throws
        -> [BenchmarkSuiteResult]
    {
        if let unavailable { return [.skipped("boot", runtime: id, reason: unavailable)] }
        switch id {
        case .tart: return [try await bootTart(ctx)]
        case .appleContainer: return [try await bootContainer(ctx, id, platform: nil)]
        case .docker:
            var results = [try await bootContainer(ctx, id, platform: nil)]
            if ctx.options.intensity == .thorough { results.append(try await bootDockerAmd64(ctx)) }
            return results
        case .host: return [try await bootHost(ctx)]
        }
    }

    // MARK: - Tart

    private static func bootTart(_ ctx: BenchmarkContext) async throws -> BenchmarkSuiteResult {
        let env = ctx.env
        guard let runtime = env.makeRuntime(.tart, nil) else {
            return .skipped("boot", runtime: .tart, reason: "tart is not supported on this build")
        }
        var clone: [Double] = [], bootToIP: [Double] = [], sshReady: [Double] = [], total: [Double] = []
        var warmStop: [Double] = [], warmBoot: [Double] = []
        return try await ctx.suite("boot", runtime: .tart, platform: nil) { steps in
            for iteration in 1...ctx.profile.iterations {
                let name = BenchmarkNaming.instanceName(runShort: ctx.runShort, index: ctx.tracker.nextIndex())
                ctx.tracker.track(name: name, runtime: runtime)
                ctx.sink.set(step: "iteration \(iteration)/\(ctx.profile.iterations)")

                try Task.checkCancellation()
                let cloned = try await BenchmarkContext.measure {
                    try await env.tart.clone(source: env.config.image, to: name)
                }
                let booted = try await BenchmarkContext.measure { () -> String in
                    try await env.tart.run(name: name)
                    return try await env.tart.ip(of: name, timeout: ctx.bootTimeout)
                }
                let ip = booted.value
                let ready = try await BenchmarkContext.measure {
                    try await GuestHostKeyPinning.pin(
                        vm: name, tart: env.tart, ssh: env.ssh, window: min(30, ctx.bootTimeout),
                        interval: .seconds(2))
                    try await awaitSSH(ctx, vm: name, ip: ip)
                }
                try Task.checkCancellation()
                clone.append(cloned.ms)
                bootToIP.append(booted.ms)
                sshReady.append(ready.ms)
                total.append(cloned.ms + booted.ms + ready.ms)

                // Warm boot: the same VM, stopped and started again (its host key is already pinned).
                ctx.sink.set(step: "warm boot \(iteration)/\(ctx.profile.iterations)")
                let stopped = try await BenchmarkContext.measure { try await env.tart.stop(name: name) }
                let restarted = try await BenchmarkContext.measure {
                    try await env.tart.run(name: name)
                    let address = try await env.tart.ip(of: name, timeout: ctx.bootTimeout)
                    try await awaitSSH(ctx, vm: name, ip: address)
                }
                warmStop.append(stopped.ms)
                warmBoot.append(restarted.ms)
                await ctx.tracker.release(name: name)
            }
            steps = [
                .summarizing("clone", milliseconds: clone),
                .summarizing("boot-to-IP", milliseconds: bootToIP),
                .summarizing("IP-to-SSH-ready", milliseconds: sshReady),
                .summarizing("cold-boot-total", milliseconds: total),
                .summarizing("warm-stop", milliseconds: warmStop),
                .summarizing("warm-boot", milliseconds: warmBoot, note: "stop → start → SSH-ready"),
            ]
        }
    }

    /// Waits for sshd to accept connections, then for one command to exit 0.
    private static func awaitSSH(_ ctx: BenchmarkContext, vm: String, ip: String) async throws {
        let deadline = Date().addingTimeInterval(max(ctx.bootTimeout, 30))
        while true {
            try Task.checkCancellation()
            if !(await ctx.env.ssh.isSSHPortOpen(ip: ip)), Date() < deadline {
                try await Task.sleep(for: ctx.env.probeInterval)
                continue
            }
            let result = try await ctx.env.ssh.exec(vm: vm, user: "admin", ip: ip, script: "true", timeout: 60)
            if result.succeeded { return }
            guard TartRuntime.sshNotListeningYet(result.stderr), Date() < deadline else {
                throw BenchmarkError.stepFailed(step: "IP-to-SSH-ready", detail: result.failureExcerpt)
            }
            try await Task.sleep(for: ctx.env.probeInterval)
        }
    }

    // MARK: - Containers

    private static func bootContainer(_ ctx: BenchmarkContext, _ id: RuntimeID, platform: LinuxPlatform?)
        async throws -> BenchmarkSuiteResult
    {
        guard let runtime = ctx.env.makeRuntime(id, platform) else {
            return .skipped("boot", runtime: id, reason: "\(id.rawValue) is not supported on this build")
        }
        let label =
            platform?.rawValue
            ?? (id == .docker ? (ctx.env.config.docker?.platform.rawValue ?? "linux/arm64") : "linux/arm64")
        var start: [Double] = [], execReady: [Double] = [], total: [Double] = []
        let notes = label == LinuxPlatform.amd64.rawValue ? ["emulated"] : []
        return try await ctx.suite("boot", runtime: id, platform: label, notes: notes) { steps in
            for iteration in 1...ctx.profile.iterations {
                let name = BenchmarkNaming.instanceName(runShort: ctx.runShort, index: ctx.tracker.nextIndex())
                ctx.tracker.track(name: name, runtime: runtime)
                ctx.sink.set(step: "iteration \(iteration)/\(ctx.profile.iterations)")
                let started = try await BenchmarkContext.measure {
                    try await runtime.provision(id: name, route: ctx.route(for: id))
                }
                let ready = try await BenchmarkContext.measure {
                    let address = try await runtime.awaitReady(id: name, timeout: ctx.bootTimeout)
                    let first = try await runtime.execRegistration(name, ip: address, "true", timeout: 120)
                    guard first.succeeded else {
                        throw BenchmarkError.stepFailed(step: "exec-ready", detail: first.failureExcerpt)
                    }
                }
                start.append(started.ms)
                execReady.append(ready.ms)
                total.append(started.ms + ready.ms)
                await ctx.tracker.release(name: name)
            }
            steps = [
                .summarizing("start", milliseconds: start, note: "create + start"),
                .summarizing("exec-ready", milliseconds: execReady, note: "running → first exec exits 0"),
                .summarizing("boot-total", milliseconds: total),
            ]
        }
    }

    /// The documented speed trap: the same image under amd64 emulation, when one is on this Mac.
    private static func bootDockerAmd64(_ ctx: BenchmarkContext) async throws -> BenchmarkSuiteResult {
        let image = ctx.env.image(for: .docker)
        guard ctx.env.config.docker?.platform != .amd64 else {
            return .skipped("boot", runtime: .docker, reason: "the configured platform already is linux/amd64")
        }
        guard await ctx.env.dockerImageArchitecture(image) == LinuxPlatform.amd64.dockerArchitecture else {
            return BenchmarkSuiteResult(
                name: "boot", runtime: RuntimeID.docker.rawValue, platform: LinuxPlatform.amd64.rawValue,
                status: .skipped, skipReason: "no linux/amd64 image '\(image)' on this Mac (emulation pass)")
        }
        return try await bootContainer(ctx, .docker, platform: .amd64)
    }

    // MARK: - Host

    private static func bootHost(_ ctx: BenchmarkContext) async throws -> BenchmarkSuiteResult {
        guard let runtime = ctx.env.makeRuntime(.host, nil) else {
            return .skipped("boot", runtime: .host, reason: "the host runtime is not supported on this build")
        }
        var spawn: [Double] = [], ready: [Double] = []
        return try await ctx.suite("boot", runtime: .host, platform: "macOS", notes: ["unisolated"]) { steps in
            for iteration in 1...ctx.profile.iterations {
                let name = BenchmarkNaming.instanceName(runShort: ctx.runShort, index: ctx.tracker.nextIndex())
                ctx.tracker.track(name: name, runtime: runtime)
                ctx.sink.set(step: "iteration \(iteration)/\(ctx.profile.iterations)")
                let spawned = try await BenchmarkContext.measure {
                    try await runtime.provision(id: name, route: ctx.route(for: .host))
                }
                let first = try await BenchmarkContext.measure { () -> ShellResult in
                    let address = try await runtime.awaitReady(id: name, timeout: ctx.bootTimeout)
                    return try await runtime.execRegistration(
                        name, ip: address,
                        "cd \(BenchmarkScripts.quote(Paths.appSupport.appendingPathComponent("host-instances/\(name)").path)) && true",
                        timeout: 120)
                }
                guard first.value.succeeded else {
                    throw BenchmarkError.stepFailed(step: "ready", detail: first.value.failureExcerpt)
                }
                spawn.append(spawned.ms)
                ready.append(first.ms)
                await ctx.tracker.release(name: name)
            }
            steps = [
                .summarizing("spawn", milliseconds: spawn, note: "work directory ready (no VM)"),
                .summarizing("ready", milliseconds: ready, note: "first exec in the scratch work directory"),
            ]
        }
    }
}
