import Foundation
import KinhinKit

enum RunCommands {
    static func start(_ args: [String]) async throws {
        Paths.ensureSupportDirectories()
        Log.setLogFile(directory: Paths.logsDirectory)
        let cfg = loadConfigOrExit()
        let engine = try engineFromConfig(cfg)
        await engine.start()
        let scopes =
            cfg.accounts.map { account -> String in
                account.forge == .github ? account.scope : "\(account.forge.rawValue): \(account.scope)"
            }.joined(separator: ", ")
        print("fleet running for \(scopes.isEmpty ? "no accounts" : scopes) — Ctrl-C to stop")
        // Park until interrupted.
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        signalSource.setEventHandler {
            print("\nstopping…")
            Task {
                await engine.stop()
                // The signal handler owns process shutdown: this task is parked
                // forever below, so there is no caller to return to.
                exit(0)
            }
        }
        signalSource.resume()
        // Park without `dispatchMain()`: it traps ("called from a block on the main queue" / "must be called on the
        // main thread") now that `main` is async, depending on which executor resumed us. A continuation nobody
        // resumes suspends this task and leaves the main queue free to deliver the SIGINT source.
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
    }

    static func stop(_ args: [String]) async throws {
        try await runControl(.stop, args: args)
    }

    static func pauseResume(_ command: String, args: [String]) async throws {
        try await runControl(command == "pause" ? .pause : .resume, args: args)
    }

    /// What `stop`/`pause`/`resume` report under `--json`.
    struct ControlResult: Codable, Equatable {
        /// `stop`, `pause` or `resume`.
        var action: String
        /// False when there was no daemon to act on (exit 1).
        var ok: Bool
        var message: String
    }

    /// The CLI half of stop/pause/resume, on the shared exit rule: 0 when the
    /// daemon did it, 1 when there is no daemon (nothing to act on), 4 when
    /// the daemon refused. `--quiet` prints nothing; `--json` prints a
    /// `ControlResult`.
    private static func runControl(_ method: RPCMethod, args: [String]) async throws {
        let json = args.contains("--json")
        let quiet = args.contains("--quiet") || args.contains("-q")
        let action = method.rawValue
        func report(_ result: ControlResult) throws {
            guard !quiet else { return }
            if json { try emitJSON(result) } else { print(result.message) }
        }
        guard let backend = await FleetBackend.attachToDaemon() else {
            try report(ControlResult(action: action, ok: false, message: noDaemonMessage(for: method)))
            ExitRule.finish(healthy: false)
            return
        }
        do {
            try report(ControlResult(action: action, ok: true, message: try await control(method, on: backend)))
        } catch let error as ControlFailure {
            fail(error.message, exit: error.exit)
        }
    }

    static func noDaemonMessage(for method: RPCMethod) -> String {
        switch method {
        case .stop:
            return "no daemon running; nothing to stop (if `kinhin start` runs elsewhere, Ctrl-C it there)"
        case .pause, .resume:
            return "no daemon running; pause/resume works while a daemon is active"
        default:
            return "no daemon running"
        }
    }

    /// The pause/resume/stop core, shared with the MCP `pause`/`resume`/`stop`
    /// tools: returns the line the CLI prints, and throws instead of exiting
    /// so a tool result can carry the failure.
    static func control(_ method: RPCMethod) async throws -> String {
        guard let backend = await FleetBackend.attachToDaemon() else {
            // A stop with nothing running is a message; pause/resume have nothing to act on.
            if method == .stop { return noDaemonMessage(for: method) }
            throw ControlFailure(noDaemonMessage(for: method), exit: .needsAttention)
        }
        return try await control(method, on: backend)
    }

    /// The one RPC switch for stop/pause/resume, on the same `FleetBackend`
    /// the app uses. A daemon refusal is a `ControlFailure` (exit 4).
    static func control(_ method: RPCMethod, on backend: any FleetServing) async throws -> String {
        do {
            switch method {
            case .stop:
                try await backend.stop()
                return "daemon fleet stopped"
            case .pause:
                try await backend.setPaused(true)
                return "fleet paused"
            case .resume:
                try await backend.setPaused(false)
                return "fleet resumed"
            default:
                throw ControlFailure("\(method.rawValue) is not a control action", exit: .usage)
            }
        } catch RPCError.rejected(let why) {
            throw ControlFailure(why)
        }
    }

    /// A control failure carrying the exit code the CLI would use for it.
    struct ControlFailure: LocalizedError {
        let message: String
        var exit: CLIExit

        init(_ message: String, exit: CLIExit = .runtime) {
            self.message = message
            self.exit = exit
        }

        var errorDescription: String? { message }
    }

    /// `kinhin status`: exits 0 when a daemon answers, 1 when none does (the
    /// fleet is not running). `--quiet` prints nothing; `--json` prints the
    /// `StatusDocument` either way.
    static func status(_ args: [String]) async throws {
        let json = args.contains("--json")
        let quiet = args.contains("--quiet") || args.contains("-q")
        let document: StatusDocument
        do {
            document = try await statusDocument()
        } catch {
            fail(error.localizedDescription, exit: .runtime)
        }
        if !quiet { try await printStatus(document, json: json) }
        ExitRule.finish(healthy: Self.isHealthy(document))
    }

    /// Healthy means a daemon answered: no daemon is "needs attention".
    static func isHealthy(_ document: StatusDocument) -> Bool {
        document.fleet != nil
    }

    private static func printStatus(_ document: StatusDocument, json: Bool) async throws {
        if let status = document.fleet {
            // Machine output only: prose before the JSON line would make the
            // document unparseable (same convention as doctor/setup-status).
            if json {
                try emitJSON(document)
            } else {
                print(FleetStatusFormatter.report(status))
            }
        } else {
            if json {
                try emitJSON(document)
                return
            }
            print("daemon: not running")
            // Capacity and orphans are extras on a "not running" answer: a
            // broken config or missing tart just leaves them out.
            let cfg: KinhinConfig? =
                FileManager.default.fileExists(atPath: Paths.config.path) ? try? ConfigLoader.load() : nil
            if let cfg {
                let host = ResourceProbe().snapshot()
                let plan = Capacity.plan(for: cfg, host: host)
                print("capacity: \(plan.maxConcurrent) concurrent VM(s) available (binding: \(plan.bindingConstraint))")
                let rpv = max(1, cfg.runnersPerVM)
                let slots = plan.maxConcurrent * rpv
                print("job slots:  \(slots) concurrent jobs (\(plan.maxConcurrent) VM(s) × runners_per_vm \(rpv))")
                if rpv >= 3, cfg.vm.memoryGB < 8 {
                    print(
                        "  note: runners_per_vm \(rpv) with \(cfg.vm.memoryGB) GB/VM risks memory contention — Xcode jobs want ~2-3 GB each"
                    )
                }
            }
            let tarts: [TartVM]
            // The orphan scan lists through the fleet's tart: honor
            // `tart_path:` like every other tart call, never a PATH lookalike.
            if let controller = try? TartController(configuredPath: cfg?.tartPath) {
                tarts = (try? await controller.list()) ?? []
            } else {
                tarts = []
            }
            let ours = tarts.filter { $0.name.hasPrefix("kinhin-") }
            if !ours.isEmpty {
                print("orphaned kinhin VMs (daemon not managing them):")
                for vm in ours { print("  \(vm.name)  \(vm.status)") }
            }
        }
    }

    /// The machine-readable status document, shared with the MCP `status`
    /// tool: "nobody is listening" reads as `daemonRunning: false`; any other
    /// failure is thrown for the caller to classify.
    static func statusDocument() async throws -> StatusDocument {
        // Ask for the status directly: a separate ping first doubled the
        // round trips. "Nobody is listening" is the only failure that means
        // "not running"; any other error propagates.
        do {
            return StatusDocument(daemonRunning: true, fleet: try RPCClient().status())
        } catch RPCError.connectionFailed {
            return StatusDocument(daemonRunning: false, fleet: nil)
        }
    }

    static func watch(_ args: [String]) async {
        while true {
            // Reuse the status command's rendering.
            // A dead or failing daemon reads as "not running" on this refresh.
            // The status call itself tells whether a daemon answers (no ping first).
            if let status = try? RPCClient().status() {
                print("\u{1B}[2J\u{1B}[H")  // clear screen
                print(FleetStatusFormatter.report(status))
                print("(refreshing every 2s — Ctrl-C to exit)")
            } else {
                print("\u{1B}[2J\u{1B}[H")
                print("daemon not running…")
            }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return  // cancelled: stop watching
            }
        }
    }

    // MARK: - Requeue / skip queued jobs

    /// `kinhin requeue <forge>` — cancel the queue's matching jobs and
    /// re-queue them. Use `--yes` to skip the confirmation.
    static func requeueQueuedJobs(_ args: [String]) async throws {
        guard
            let forgeId = args.first(where: {
                !hasFlag($0, in: args) && !$0.hasPrefix("--") && $0 != "--help" && $0 != "-h"
            })
        else {
            fail("usage: kinhin requeue <forge> [--yes]", exit: .usage)
        }
        let confirmed = hasFlag("--yes", in: args)
        guard let forge = ForgeID(rawValue: forgeId) else {
            fail(
                "unknown forge '\(forgeId)'; available: \(ForgeID.allCases.map(\.rawValue).joined(separator: ", ")), or add one in config first",
                exit: .usage)
        }
        try await runRequeue(for: forge, confirmed: confirmed)
    }

    /// `kinhin skip <forge>` — mark the queue's matching jobs as skipped.
    static func skipQueuedJobs(_ args: [String]) async throws {
        guard
            let forgeId = args.first(where: {
                !hasFlag($0, in: args) && !$0.hasPrefix("--") && $0 != "--help" && $0 != "-h"
            })
        else {
            fail("usage: kinhin skip <forge> [--yes]", exit: .usage)
        }
        let confirmed = hasFlag("--yes", in: args)
        guard let forge = ForgeID(rawValue: forgeId) else {
            fail(
                "unknown forge '\(forgeId)'; available: \(ForgeID.allCases.map(\.rawValue).joined(separator: ", ")), or add one in config first",
                exit: .usage)
        }
        try await runSkip(for: forge, confirmed: confirmed)
    }

    /// Driver shared by `requeue` and `skip`: owns the confirmation and
    /// dispatches to the running daemon. A headless CLI only talks to the daemon;
    /// there is no in-process backend here (the app manages that).
    static func runRequeue(for forge: ForgeID, confirmed: Bool) async throws {
        guard confirmed else {
            print("would requeue the queued jobs of '\(forge.displayName)' (use --yes to confirm)")
            return
        }
        guard RPCClient.isDaemonAlive() else {
            fail("no daemon running; requeue/skip works while a daemon is active", exit: .runtime)
        }
        let response = try RPCClient().command(
            .requeueQueuedJobs, payload: try JSONEncoder().encode(Daemon.ForgeJobsRequest(forge: forge)))
        guard response.ok else { fail(response.error ?? "could not requeue queued jobs", exit: .runtime) }
        print("requeued queued jobs for '\(forge.displayName)'")
    }

    static func runSkip(for forge: ForgeID, confirmed: Bool) async throws {
        guard confirmed else {
            print("would skip the queued jobs of '\(forge.displayName)' (use --yes to confirm)")
            return
        }
        guard RPCClient.isDaemonAlive() else {
            fail("no daemon running; requeue/skip works while a daemon is active", exit: .runtime)
        }
        let response = try RPCClient().command(
            .skipQueuedJobs, payload: try JSONEncoder().encode(Daemon.ForgeJobsRequest(forge: forge)))
        guard response.ok else { fail(response.error ?? "could not skip queued jobs", exit: .runtime) }
        print("skipped queued jobs for '\(forge.displayName)'")
    }

    /// The tail of the log file, redacted for tokens: the same lines the MCP `logs` tool returns. This read the
    /// in-memory log of its own (fresh) process, which is always empty, so it never showed the daemon's history
    /// (found by the e2e suite on a busy fleet).
    static func logs(_ args: [String]) {
        let count = max(1, min(Int(flag("-n", in: args) ?? "50") ?? 50, 5000))
        let file = Paths.logsDirectory.appendingPathComponent("kinhin.log")
        let tail = SupportBundle.tail(of: file, lines: count)
        guard !tail.isEmpty else {
            print("no log lines yet; logs live at \(Paths.logsDirectory.path)")
            return
        }
        for line in tail.components(separatedBy: "\n") { print(Log.redact(line)) }
    }

    /// The `kinhin daemon install` core, shared with the MCP `daemon_install`
    /// tool: validates the binary, writes the LaunchAgent and loads it —
    /// throwing instead of printing or exiting.
    static func installLaunchAgent() async throws {
        // The LaunchAgent runs this path at every login: it must be absolute (a relative
        // argv[0] resolves against whatever the cwd is at launch) and a built release, not a
        // debug binary that carries development-only token handling.
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        if binary.contains("/.build/debug/") || binary.contains("/.build/arm64-apple-macosx/debug/") {
            throw ControlFailure(
                "refusing to install a LaunchAgent for a debug build (\(binary)); install a release build",
                exit: .usage)
        }
        try Daemon.installAgent(binaryPath: binary)
        // launchctl load
        let shell = Shell()
        let res = try await shell.run(["launchctl", "load", Daemon.agentPlistPath().path], cwd: nil, timeout: 30)
        guard res.succeeded else { throw ControlFailure("launchctl load failed: \(res.stderr)", exit: .runtime) }
    }

    static func daemon(_ args: [String]) async throws {
        if args.contains("install") {
            do {
                try await installLaunchAgent()
            } catch let error as ControlFailure {
                fail(error.message, exit: error.exit)
            }
            print("daemon installed and started")
        } else if args.contains("uninstall") {
            // Shared with reset's daemon scope: bootout/unload best-effort,
            // then both plists (current and pre-rename label) removed.
            try await Daemon.stopAndUninstall()
            print("daemon uninstalled")
        } else {
            // Foreground daemon.
            Paths.ensureSupportDirectories()
            Log.setLogFile(directory: Paths.logsDirectory)
            do {
                try await Daemon.run()
            } catch {
                fail(error)
            }
        }
    }
}
