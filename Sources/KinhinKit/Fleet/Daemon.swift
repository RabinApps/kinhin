import Foundation

/// Runs the fleet engine headless behind the unix-socket RPC server.
public enum Daemon {
    public static let label = "com.kinhin.daemon"
    static let plistName = "com.kinhin.daemon.plist"

    /// Boot the engine and block forever serving RPC.
    public static func run() async throws {
        Paths.ensureSupportDirectories()
        Log.setLogFile(directory: Paths.logsDirectory)

        if RPCClient.isDaemonAlive() {
            Log.warn(
                "daemon",
                "another daemon appears to be running; continuing anyway (bind will fail if the socket is taken)")
        }

        let cfg: KinhinConfig
        do {
            cfg = try ConfigLoader.load()
        } catch {
            Log.error("daemon", "config problem: \(error.localizedDescription)")
            throw error
        }
        guard let pat = ConfigLoader.engineToken(for: cfg) else {
            let message =
                cfg.githubEnabled
                ? "no GitHub token in Keychain — run `kinhin auth` first"
                : "no forge ready — set a GitHub repo or a gitea: section, and store its token (`kinhin auth set`)"
            Log.error("daemon", message)
            throw DaemonError.missingToken
        }
        guard cfg.canRunOnThisHost() else {
            Log.error("daemon", "tart binary not found")
            throw TartError.missingBinary(path: cfg.tartPath ?? "PATH")
        }

        let engineRef = EngineRef()
        do {
            engineRef.set(try buildEngine(cfg))
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
        try RPCServer.serve(socketURL: RPCPaths.socket) { request in
            await Self.handle(request, engineRef: engineRef)
        }
    }

    /// Wire a fresh engine for the given config (production collaborators:
    /// Keychain PAT, tart at the configured path, the shared default store).
    /// Called again on every config-reload rebuild, so a rebuilt engine
    /// keeps serving through the same RPC server.
    static func buildEngine(_ cfg: KinhinConfig) throws -> FleetEngine {
        guard let pat = ConfigLoader.engineToken(for: cfg) else {
            throw DaemonError.missingToken
        }
        let tart = try cfg.makeTartControlling()
        return FleetEngine(
            config: cfg,
            pat: pat,
            tart: tart,
            store: FleetStore(),
            ssh: SSHExecutor(),
            host: ResourceProbe().snapshot()
        )
    }

    /// Thread-safe box around the "current" engine. A config edit that the
    /// running engine cannot adopt live (anything beyond routing) requires
    /// a rebuild — the server's handler keeps answering through this box
    /// while the swap happens.
    final class EngineRef: @unchecked Sendable {
        private let lock = NSLock()
        private var wrapped: FleetEngine?

        public init(_ initial: FleetEngine? = nil) {
            wrapped = initial
        }

        public var engine: FleetEngine? {
            lock.withLock { wrapped }
        }

        func set(_ engine: FleetEngine?) {
            lock.withLock { wrapped = engine }
        }
    }

    /// Legacy/compat entry: a fixed engine, wrapped in a throwaway ref.
    /// (Production serves through engineRef so a reload can swap it.)
    static func handle(_ request: RPCRequest, engine: FleetEngine, configURL: URL = Paths.config) async -> RPCResponse {
        await handle(request, engineRef: EngineRef(engine), configURL: configURL)
    }

    /// configURL is injectable so tests can exercise reload hermetically.
    /// The engine comes in through engineRef: a scope/shape edit forces a
    /// rebuild (fresh engine from the new file) rather than a live reload.
    /// The factory defaults to the production collaborators; tests inject
    /// one so a rebuild never touches the Keychain or tart.
    static func handle(
        _ request: RPCRequest,
        engineRef: EngineRef,
        configURL: URL = Paths.config,
        engineFactory: ((KinhinConfig) throws -> FleetEngine)? = nil
    ) async -> RPCResponse {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        /// Decodes the request payload, logging why a malformed one was rejected.
        func decodePayload<T: Decodable>(_ type: T.Type) -> T? {
            guard let payload = request.payload else { return nil }
            do {
                return try decoder.decode(type, from: payload)
            } catch {
                Log.warn("daemon", "rejected malformed \(request.method) payload: \(error)")
                return nil
            }
        }
        do {
            // Resolve the engine per request (a rebuild swaps the box's
            // contents mid-flight; every method reads it fresh).
            guard let engine = engineRef.engine else {
                return RPCResponse(
                    id: request.id, ok: false, error: "no engine (rebuild failed) — fix the config and edit again")
            }
            switch request.method {
            case .ping:
                return RPCResponse(id: request.id, ok: true, payload: try encoder.encode(["pong": true]))
            case .status:
                let status = await engine.status()
                return RPCResponse(id: request.id, ok: true, payload: try encoder.encode(status))
            case .start:
                await engine.start()
                return RPCResponse(id: request.id, ok: true)
            case .stop:
                await engine.stop()
                return RPCResponse(id: request.id, ok: true)
            case .pause:
                await engine.setPaused(true)
                return RPCResponse(id: request.id, ok: true)
            case .resume:
                await engine.setPaused(false)
                return RPCResponse(id: request.id, ok: true)
            case .deleteVM:
                guard let id = decodePayload(VMDeleteRequest.self)?.id else {
                    return RPCResponse(id: request.id, ok: false, error: "expected {\"id\": \"...\"}")
                }
                await engine.deleteVM(id: id)
                return RPCResponse(id: request.id, ok: true)
            case .replaceGiteaToken:
                guard let replacement = decodePayload(GiteaTokenReplaceRequest.self) else {
                    return RPCResponse(id: request.id, ok: false, error: "expected {\"token\": \"...\"}")
                }
                await engine.replaceGiteaToken(replacement.token)
                return RPCResponse(id: request.id, ok: true)
            case .replaceAccountToken:
                guard let replacement = decodePayload(AccountTokenReplaceRequest.self) else {
                    return RPCResponse(
                        id: request.id, ok: false, error: "expected {\"account\": \"...\", \"token\": \"...\"}")
                }
                await engine.replaceToken(account: replacement.account, token: replacement.token)
                return RPCResponse(id: request.id, ok: true)
            case .replaceToken:
                guard let replacement = decodePayload(TokenReplaceRequest.self) else {
                    return RPCResponse(id: request.id, ok: false, error: "expected {\"pat\": \"...\"}")
                }
                // The caller (app or CLI) has already saved the token to the
                // Keychain; the daemon just swaps its in-memory client.
                await engine.replaceCredentials(pat: replacement.pat)
                return RPCResponse(id: request.id, ok: true)
            case .reloadConfig:
                // The Runtimes pane, Config tab, or CLI just rewrote
                // config.yaml. Routing-only edits apply live to the running
                // engine; anything else (scope, bounds, VM shape, images,
                // forge sections) requires rebuilding the engine from the
                // new file. Failure (bad YAML, validation) leaves the
                // running fleet untouched on its current config.
                do {
                    let cfg = try ConfigLoader.load(from: configURL)
                    if FleetEngine.restartRequired(from: engine.activeConfig, to: cfg) {
                        let replacement = try (engineFactory ?? Self.buildEngine)(cfg)
                        let wasRunning = await engine.status().running
                        let wasPaused = await engine.status().paused
                        // A stopped fleet stays stopped across a rebuild — a
                        // config edit must never start spawning VMs.
                        if wasRunning {
                            await replacement.start()
                            if wasPaused { await replacement.setPaused(true) }
                        }
                        let status = await replacement.status()
                        if wasRunning, !status.running, let error = status.lastError {
                            // Startup verification failed (bad PAT, transient
                            // network): keep the old engine serving instead
                            // of trading a running fleet for a dead one.
                            Log.error("daemon", "rebuild did not start: \(error) — keeping the previous engine")
                            return RPCResponse(id: request.id, ok: false, error: "restart failed: \(error)")
                        }
                        await engine.detachKeepingInstances()
                        engineRef.set(replacement)
                        Log.info(
                            "daemon",
                            "config change required a restart — engine rebuilt (running: \(wasRunning), paused: \(wasPaused))"
                        )
                        return RPCResponse(id: request.id, ok: true)
                    }
                    await engine.applyReloaded(config: cfg, host: ResourceProbe().snapshot())
                    return RPCResponse(id: request.id, ok: true)
                } catch {
                    return RPCResponse(id: request.id, ok: false, error: "reload failed: \(error.localizedDescription)")
                }
            case .logs:
                let entries = Log.snapshot(limit: 300)
                return RPCResponse(id: request.id, ok: true, payload: try encoder.encode(entries))
            }
        } catch {
            return RPCResponse(id: request.id, ok: false, error: error.localizedDescription)
        }
    }

    public struct VMDeleteRequest: Codable {
        public let id: String
        public init(id: String) { self.id = id }
    }

    enum DaemonError: LocalizedError {
        case missingToken
        case alreadyRunning
        case configProblem(String)

        public var errorDescription: String? {
            switch self {
            case .missingToken: return "no GitHub token stored — run `kinhin auth`"
            case .alreadyRunning: return "a daemon is already running"
            case .configProblem(let why): return "config problem: \(why)"
            }
        }
    }

    // MARK: - LaunchAgent

    public static func agentPlistPath() -> URL {
        Paths.userLibrarySubdirectory(.libraryDirectory, fallback: "Library")
            .appendingPathComponent("LaunchAgents/\(plistName)")
    }

    /// Write the LaunchAgent plist pointing at the given kinhin binary.
    public static func installAgent(binaryPath: String) throws {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.kinhin.daemon</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(binaryPath)</string>
                    <string>daemon</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <true/>
                <key>StandardOutPath</key>
                <string>\(Paths.logsDirectory.appendingPathComponent("daemon.out.log").path)</string>
                <key>StandardErrorPath</key>
                <string>\(Paths.logsDirectory.appendingPathComponent("daemon.err.log").path)</string>
            </dict>
            </plist>
            """
        let url = agentPlistPath()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist.write(to: url, atomically: true, encoding: .utf8)
        Log.info("daemon", "launchagent written to \(url.path)")
    }

    public static func uninstallAgent() throws {
        let fm = FileManager.default
        // Pre-rename builds installed under the com.orchard.daemon label.
        let legacy = Paths.userLibrarySubdirectory(.libraryDirectory, fallback: "Library")
            .appendingPathComponent("LaunchAgents/com.orchard.daemon.plist")
        for url in [agentPlistPath(), legacy] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }
}
