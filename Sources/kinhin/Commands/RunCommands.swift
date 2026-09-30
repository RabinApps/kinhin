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
        if RPCClient.isDaemonAlive() {
            let response = try RPCClient().send(method: .stop)
            if response.ok {
                print("daemon fleet stopped")
            } else {
                fail(response.error ?? "unknown error", exit: .runtime)
            }
        } else {
            print("no daemon running; nothing to stop (if `kinhin start` runs elsewhere, Ctrl-C it there)")
        }
    }

    static func pauseResume(_ command: String, args: [String]) throws {
        let method: RPCMethod = command == "pause" ? .pause : .resume
        if RPCClient.isDaemonAlive() {
            let response = try RPCClient().send(method: method)
            guard response.ok else { fail(response.error ?? "unknown error", exit: .runtime) }
            print(command == "pause" ? "fleet paused" : "fleet resumed")
        } else {
            fail("no daemon running; pause/resume works while a daemon is active", exit: .runtime)
        }
    }

    static func status(_ args: [String]) async throws {
        func emitJSON(_ document: StatusDocument) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(document), as: UTF8.self))
        }
        if RPCClient.isDaemonAlive() {
            let status: FleetStatus
            do {
                status = try RPCClient().status()
            } catch {
                fail(error.localizedDescription, exit: .runtime)
            }
            // Machine output only: prose before the JSON line would make the
            // document unparseable (same convention as doctor/setup-status).
            if args.contains("--json") {
                try emitJSON(StatusDocument(daemonRunning: true, fleet: status))
            } else {
                print(renderStatus(status))
            }
        } else {
            if args.contains("--json") {
                try emitJSON(StatusDocument(daemonRunning: false, fleet: nil))
                return
            }
            print("daemon: not running")
            if FileManager.default.fileExists(atPath: Paths.config.path),
                let cfg = try? ConfigLoader.load()
            {
                let host = ResourceProbe().snapshot()
                let plan = Capacity.plan(
                    host: host,
                    vmCPU: cfg.vm.cpuCount,
                    vmMemoryGB: cfg.vm.memoryGB,
                    reservedCPU: cfg.reserve.cpu,
                    reservedMemoryGB: cfg.reserve.memoryGB,
                    diskPerVMGB: cfg.diskGB ?? 0,
                    userMax: cfg.maxRunners
                )
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

    static func watch(_ args: [String]) async {
        while true {
            // Reuse the status command's rendering.
            // A dead or failing daemon reads as "not running" on this refresh.
            if RPCClient.isDaemonAlive(), let status = try? RPCClient().status() {
                print("\u{1B}[2J\u{1B}[H")  // clear screen
                print(renderStatus(status))
                print("(refreshing every 2s — Ctrl-C to exit)")
            } else {
                print("\u{1B}[2J\u{1B}[H")
                print("daemon not running…")
            }
            try? await Task.sleep(for: .seconds(2))
        }
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

    static func daemon(_ args: [String]) async throws {
        if args.contains("install") {
            let binary = CommandLine.arguments[0]
            try Daemon.installAgent(binaryPath: binary)
            // launchctl load
            let shell = Shell()
            let res = try await shell.run(["launchctl", "load", Daemon.agentPlistPath().path], cwd: nil, timeout: 30)
            guard res.succeeded else { fail("launchctl load failed: \(res.stderr)", exit: .runtime) }
            print("daemon installed and started")
        } else if args.contains("uninstall") {
            let shell = Shell()
            do {
                _ = try await shell.run(["launchctl", "unload", Daemon.agentPlistPath().path], cwd: nil, timeout: 30)
            } catch {
                // Unloading an agent that isn't loaded is fine; only a launch failure is worth mentioning.
                warn("could not run launchctl unload (\(error.localizedDescription)); removing the plist anyway")
            }
            try Daemon.uninstallAgent()
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
