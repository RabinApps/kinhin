import Foundation
import OrchardKit

enum RunCommands {
    static func start(_ args: [String]) async throws {
        Paths.ensureSupportDirectories()
        Log.setLogFile(directory: Paths.logsDirectory)
        let cfg = loadConfigOrExit()
        let engine = try engineFromConfig(cfg)
        await engine.start()
        print("fleet running for \(cfg.repo) — Ctrl-C to stop")
        // Park until interrupted.
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        signalSource.setEventHandler {
            print("\nstopping…")
            Task {
                await engine.stop()
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
                fail(response.error ?? "unknown error")
            }
        } else {
            print("no daemon running; nothing to stop (if `orchard start` runs elsewhere, Ctrl-C it there)")
        }
    }

    static func pauseResume(_ command: String, args: [String]) throws {
        let method: RPCMethod = command == "pause" ? .pause : .resume
        if RPCClient.isDaemonAlive() {
            let response = try RPCClient().send(method: method)
            guard response.ok else { fail(response.error ?? "unknown error") }
            print(command == "pause" ? "fleet paused" : "fleet resumed")
        } else {
            fail("no daemon running; pause/resume works while a daemon is active")
        }
    }

    static func status(_ args: [String]) async throws {
        if RPCClient.isDaemonAlive() {
            let response = try RPCClient().send(method: .status)
            guard response.ok, let payload = response.payload else {
                fail(response.error ?? "daemon returned no payload")
            }
            let status = try JSONDecoder().decode(FleetStatus.self, from: payload)
            print(renderStatus(status))
            if args.contains("--json") {
                let data = try JSONEncoder().encode(status)
                print(String(decoding: data, as: UTF8.self))
            }
        } else {
            print("daemon: not running")
            if FileManager.default.fileExists(atPath: Paths.config.path),
               let cfg = try? ConfigLoader.load() {
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
                print("  note: runners_per_vm \(rpv) with \(cfg.vm.memoryGB) GB/VM risks memory contention — Xcode jobs want ~2-3 GB each")
            }
            }
            let tarts: [TartVM]
            if let controller = try? TartController() {
                tarts = (try? await controller.list()) ?? []
            } else {
                tarts = []
            }
            let ours = tarts.filter { $0.name.hasPrefix("orchard-") }
            if !ours.isEmpty {
                print("orphaned orchard VMs (daemon not managing them):")
                for vm in ours { print("  \(vm.name)  \(vm.status)") }
            }
        }
    }

    static func watch(_ args: [String]) async {
        while true {
            // Reuse the status command's rendering.
            if RPCClient.isDaemonAlive(), let response = try? RPCClient().send(method: .status),
               response.ok, let payload = response.payload,
               let status = try? JSONDecoder().decode(FleetStatus.self, from: payload) {
                print("\u{1B}[2J\u{1B}[H") // clear screen
                print(renderStatus(status))
                print("(refreshing every 2s — Ctrl-C to exit)")
            } else {
                print("\u{1B}[2J\u{1B}[H")
                print("daemon not running…")
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
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
            guard res.succeeded else { fail("launchctl load failed: \(res.stderr)") }
            print("daemon installed and started")
        } else if args.contains("uninstall") {
            let shell = Shell()
            _ = try? await shell.run(["launchctl", "unload", Daemon.agentPlistPath().path], cwd: nil, timeout: 30)
            try Daemon.uninstallAgent()
            print("daemon uninstalled")
        } else {
            // Foreground daemon.
            Paths.ensureSupportDirectories()
            Log.setLogFile(directory: Paths.logsDirectory)
            do {
                try await Daemon.run()
            } catch {
                fail(error.localizedDescription)
            }
        }
    
    }
}
