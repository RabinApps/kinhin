import Foundation

/// Runs the fleet engine headless behind the unix-socket RPC server.
public enum Daemon {
    /// The LaunchAgent plist that `kinhin daemon install` wrote, if any.
    public static var agentPlistURL: URL? {
        let url = agentPlistPath()
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The binary path stored in the LaunchAgent plist's `ProgramArguments`,
    /// if the plist exists and declares one. Nil when there is no LaunchAgent
    /// or the plist cannot be read.
    public static var plistBinaryPath: String? {
        guard let url = agentPlistURL else { return nil }
        // Documented above: no readable plist means no installed binary path.
        guard let plist = try? Data(contentsOf: url),
            // An unparseable plist is the same "no binary path" answer.
            let root = try? PropertyListSerialization.propertyList(
                from: plist, options: [],
                format: nil) as? [String: Any],
            let args = root["ProgramArguments"] as? [String], args.count > 0
        else { return nil }
        return args[0]
    }

    /// Whether the LaunchAgent plist points at a binary that no longer exists
    /// on disk. True when a LaunchAgent is installed but its `kinhin` binary
    /// has been moved or deleted (e.g. after `bash scripts/install.sh --uninstall`
    /// without also running `kinhin daemon uninstall`).
    public static var isPlistStale: Bool {
        guard let path = plistBinaryPath else { return false }
        return !FileManager.default.fileExists(atPath: path)
    }
    public static let label = "com.kinhin.daemon"
    static let plistName = "com.kinhin.daemon.plist"

    /// Boot the engine and block forever serving RPC. A startup failure flushes telemetry first, so the record
    /// that says why the daemon is down still reaches the collector.
    public static func run() async throws {
        do {
            try await serve()
        } catch {
            await TelemetryService.shared.shutdown()
            throw error
        }
    }

    private static func serve() async throws {
        Paths.ensureSupportDirectories()
        Log.setLogFile(directory: Paths.logsDirectory)

        // One daemon per host: two would both scale the fleet, and the second
        // RPC bind would silently steal the first one's socket.
        let instanceLock: DaemonLock
        do {
            instanceLock = try DaemonLock.acquire()
        } catch {
            Log.error("daemon", "not starting: \(error.localizedDescription)")
            throw error
        }
        defer { withExtendedLifetime(instanceLock) {} }
        // A daemon from before the lock existed still answers on the socket.
        if RPCClient.isDaemonAlive() {
            Log.error("daemon", "not starting: another daemon is already serving \(RPCPaths.socket.path)")
            throw DaemonError.alreadyRunning
        }

        let cfg: KinhinConfig
        do {
            cfg = try ConfigLoader.load()
        } catch {
            Log.error("daemon", "config problem: \(error.localizedDescription)")
            throw error
        }
        // Telemetry starts once per process, before the engine, and is flushed on SIGTERM/SIGINT.
        await TelemetryService.shared.apply(cfg.telemetry)
        let terminationSources = installTerminationFlush()
        defer { withExtendedLifetime(terminationSources) {} }

        let enginePAT: String?
        do {
            enginePAT = try ConfigLoader.engineToken(for: cfg)
        } catch {
            Log.error("daemon", error.localizedDescription)
            throw error
        }
        guard let enginePAT else {
            let message =
                cfg.githubEnabled
                ? "no GitHub token in Keychain — run `kinhin auth` first"
                : !cfg.accounts.isEmpty
                    ? "no account has a token in Keychain — run `kinhin auth list`, then `kinhin auth set --account NAME`"
                    : "no forge ready — add an account under `accounts:` in the config, and store its token (`kinhin auth set --account NAME`)"
            Log.error("daemon", message)
            throw DaemonError.missingToken
        }
        guard cfg.canRunOnThisHost() else {
            Log.error("daemon", "tart binary not found")
            throw TartError.missingBinary(path: cfg.tartPath ?? "PATH")
        }

        let engineRef = EngineRef()
        do {
            // The token was just read above; reuse it instead of a second Keychain read.
            engineRef.set(try FleetEngine.production(config: cfg, token: enginePAT))
        } catch {
            Log.error("daemon", "could not build engine: \(error.localizedDescription)")
            throw error
        }

        Log.info("daemon", "starting engine for \(cfg.allAccounts.map(\.name).joined(separator: ", "))")
        await engineRef.engine?.start()
        // The engine self-gates on runner permission (org PATs fail fast);
        // surface a blocked startup instead of idling silently.
        if let status = await engineRef.engine?.status(), !status.running, let error = status.lastError {
            Log.error("daemon", "engine did not start: \(error)")
        }

        Log.info("daemon", "serving RPC on \(RPCPaths.socket.path)")
        try await RPCServer.serve(socketURL: RPCPaths.socket) { request in
            await Self.handle(request, engineRef: engineRef)
        }
    }

    /// Flushes telemetry before the process ends on SIGTERM (launchctl stop) or SIGINT. Without a
    /// handler the last export interval of metrics, spans and logs would be lost.
    private static func installTerminationFlush() -> [any DispatchSourceSignal] {
        [SIGTERM, SIGINT].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                Task {
                    await TelemetryService.shared.shutdown()
                    exit(0)
                }
            }
            source.resume()
            return source
        }
    }

    /// Wire a fresh engine for the given config (production collaborators:
    /// Keychain PAT, tart at the configured path, the shared default store).
    /// Called again on every config-reload rebuild, so a rebuilt engine
    /// keeps serving through the same RPC server.
    static func buildEngine(_ cfg: KinhinConfig) throws -> FleetEngine {
        guard let pat = try ConfigLoader.engineToken(for: cfg) else {
            throw DaemonError.missingToken
        }
        return try FleetEngine.production(config: cfg, token: pat)
    }
}
