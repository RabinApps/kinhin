import Foundation

/// Runs the fleet engine headless behind the unix-socket RPC server.
public enum Daemon {
    public static let label = "com.orchard.daemon"
    public static let plistName = "com.orchard.daemon.plist"

    /// Boot the engine and block forever serving RPC.
    public static func run() async throws {
        Paths.ensureSupportDirectories()
        Log.setLogFile(directory: Paths.logsDirectory)

        if RPCClient.isDaemonAlive() {
            Log.warn("daemon", "another daemon appears to be running; continuing anyway (bind will fail if the socket is taken)")
        }

        let cfg: OrchardConfig
        do {
            cfg = try ConfigLoader.load()
        } catch {
            Log.error("daemon", "config problem: \(error.localizedDescription)")
            throw error
        }
        guard let pat = KeychainTokenStore.load() else {
            let message = "no GitHub token in Keychain — run `orchard auth` first"
            Log.error("daemon", message)
            throw DaemonError.missingToken
        }
        guard TartController.isInstalled(configuredPath: cfg.tartPath) else {
            Log.error("daemon", "tart binary not found")
            throw TartError.missingBinary(path: cfg.tartPath ?? "PATH")
        }

        let tart = try TartController(configuredPath: cfg.tartPath)
        let host = ResourceProbe().snapshot()
        // Factory-based init so `replace_token` RPC swaps the client live.
        let engine = FleetEngine(
            config: cfg,
            pat: pat,
            tart: tart,
            store: FleetStore(),
            ssh: SSHExecutor(),
            host: host
        )

        Log.info("daemon", "starting engine for \(cfg.repo)")
        await engine.start()
        // The engine self-gates on runner permission (org PATs fail fast);
        // surface a blocked startup instead of idling silently.
        let status = await engine.status()
        if !status.running, let error = status.lastError {
            Log.error("daemon", "engine did not start: \(error)")
        }

        Log.info("daemon", "serving RPC on \(RPCPaths.socket.path)")
        try RPCServer.serve(socketURL: RPCPaths.socket) { request in
            await Self.handle(request, engine: engine)
        }
    }

    /// configURL is injectable so tests can exercise reload hermetically.
    static func handle(_ request: RPCRequest, engine: FleetEngine, configURL: URL = Paths.config) async -> RPCResponse {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        do {
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
                guard let payload = request.payload,
                      let id = try? decoder.decode(VMDeleteRequest.self, from: payload).id else {
                    return RPCResponse(id: request.id, ok: false, error: "expected {\"id\": \"...\"}")
                }
                await engine.deleteVM(id: id)
                return RPCResponse(id: request.id, ok: true)
            case .replaceGiteaToken:
                guard let payload = request.payload,
                      let replacement = try? decoder.decode(GiteaTokenReplaceRequest.self, from: payload) else {
                    return RPCResponse(id: request.id, ok: false, error: "expected {\"token\": \"...\"}")
                }
                await engine.replaceGiteaToken(replacement.token)
                return RPCResponse(id: request.id, ok: true)
            case .replaceToken:
                guard let payload = request.payload,
                      let replacement = try? decoder.decode(TokenReplaceRequest.self, from: payload) else {
                    return RPCResponse(id: request.id, ok: false, error: "expected {\"pat\": \"...\"}")
                }
                // The caller (app or CLI) has already saved the token to the
                // Keychain; the daemon just swaps its in-memory client.
                await engine.replaceCredentials(pat: replacement.pat)
                return RPCResponse(id: request.id, ok: true)
            case .reloadConfig:
                // The Runtimes pane (or CLI) just rewrote config.yaml; reload
                // the routing state from the file on disk. Failure (bad YAML,
                // validation) leaves the running fleet on its current config.
                do {
                    let cfg = try ConfigLoader.load(from: configURL)
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

    public enum DaemonError: LocalizedError {
        case missingToken
        case alreadyRunning
        case configProblem(String)

        public var errorDescription: String? {
            switch self {
            case .missingToken: return "no GitHub token stored — run `orchard auth`"
            case .alreadyRunning: return "a daemon is already running"
            case .configProblem(let why): return "config problem: \(why)"
            }
        }
    }

    // MARK: - LaunchAgent

    public static func agentPlistPath() -> URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return lib.appendingPathComponent("LaunchAgents/\(plistName)")
    }

    /// Write the LaunchAgent plist pointing at the given orchard binary.
    public static func installAgent(binaryPath: String) throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.orchard.daemon</string>
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
        try? FileManager.default.removeItem(at: agentPlistPath())
    }
}
