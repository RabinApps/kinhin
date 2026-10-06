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
                // The signal handler owns process shutdown: the main queue is
                // parked in dispatchMain(), so there is no caller to return to.
                exit(0)
            }
        }
        signalSource.resume()
        dispatchMain()
    }

    static func stop(_ args: [String]) throws {
        do {
            print(try control(.stop))
        } catch let error as ControlFailure {
            fail(error.message, exit: error.exit)
        }
    }

    static func pauseResume(_ command: String, args: [String]) throws {
        let method: RPCMethod = command == "pause" ? .pause : .resume
        do {
            print(try control(method))
        } catch let error as ControlFailure {
            fail(error.message, exit: error.exit)
        }
    }

    /// The pause/resume/stop core, shared with the MCP `pause`/`resume`/`stop`
    /// tools: returns the line the CLI prints, and throws instead of exiting
    /// so a tool result can carry the failure.
    static func control(_ method: RPCMethod) throws -> String {
        guard RPCClient.isDaemonAlive() else {
            switch method {
            case .stop:
                return "no daemon running; nothing to stop (if `kinhin start` runs elsewhere, Ctrl-C it there)"
            case .pause, .resume:
                throw ControlFailure("no daemon running; pause/resume works while a daemon is active")
            default:
                throw ControlFailure("no daemon running")
            }
        }
        let response = try RPCClient().send(method: method)
        guard response.ok else { throw ControlFailure(response.error ?? "unknown error") }
        switch method {
        case .stop: return "daemon fleet stopped"
        case .pause: return "fleet paused"
        case .resume: return "fleet resumed"
        default: return "done"
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

    static func status(_ args: [String]) async throws {
        func emitJSON(_ document: StatusDocument) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(document), as: UTF8.self))
        }
        let document: StatusDocument
        do {
            document = try await statusDocument()
        } catch {
            fail(error.localizedDescription, exit: .runtime)
        }
        if let status = document.fleet {
            // Machine output only: prose before the JSON line would make the
            // document unparseable (same convention as doctor/setup-status).
            if args.contains("--json") {
                try emitJSON(document)
            } else {
                print(FleetStatusFormatter.report(status))
            }
        } else {
            if args.contains("--json") {
                try emitJSON(document)
                return
            }
            print("daemon: not running")
            // Capacity and orphans are extras on a "not running" answer: a
            // broken config or missing tart just leaves them out.
            if FileManager.default.fileExists(atPath: Paths.config.path),
                let cfg = try? ConfigLoader.load()
            {
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
            if let controller = try? TartController() {
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

    static func logs(_ args: [String]) {
        let count = Int(flag("-n", in: args) ?? "50") ?? 50
        let entries = Log.snapshot(limit: count)
        if entries.isEmpty {
            print("no in-memory logs; daemon logs live at \(Paths.logsDirectory.path)")
        } else {
            for entry in entries { print(entry.formatted) }
        }
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
