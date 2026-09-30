import Foundation
import Synchronization

/// Runs the fleet engine headless behind the unix-socket RPC server.
public enum Daemon {
    public static let label = "com.kinhin.daemon"
    static let plistName = "com.kinhin.daemon.plist"

    /// Boot the engine and block forever serving RPC.
    public static func run() async throws {
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
        let enginePAT: String?
        do {
            enginePAT = try ConfigLoader.engineToken(for: cfg)
        } catch {
            Log.error("daemon", error.localizedDescription)
            throw error
        }
        guard enginePAT != nil else {
            let message =
                cfg.githubEnabled
                ? "no GitHub token in Keychain — run `kinhin auth` first"
                : !cfg.accounts.isEmpty
                    ? "no account has a token in Keychain — run `kinhin auth list`, then `kinhin auth set --account NAME`"
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
        try await RPCServer.serve(socketURL: RPCPaths.socket) { request in
            await Self.handle(request, engineRef: engineRef)
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

    /// Thread-safe box around the "current" engine. A config edit that the
    /// running engine cannot adopt live (anything beyond routing) requires
    /// a rebuild — the server's handler keeps answering through this box
    /// while the swap happens.
    /// FleetEngine is checked-`Sendable` now, so the current-engine box is
    /// just a stdlib `Mutex` — no unchecked escape hatch needed.
    final class EngineRef: Sendable {
        private let wrapped: Mutex<FleetEngine?>

        public init(_ initial: FleetEngine? = nil) {
            wrapped = Mutex(initial)
        }

        public var engine: FleetEngine? {
            wrapped.withLock { $0 }
        }

        func set(_ engine: FleetEngine?) {
            wrapped.withLock { $0 = engine }
        }

        /// The tail of the serial chain: each `serialized` call runs after
        /// the previous one finished.
        private let tail = Mutex<Task<Void, Never>?>(nil)

        /// Run `operation` after every previously submitted one has finished
        /// (FIFO), so engine swaps never interleave.
        func serialized<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
            let task = tail.withLock { tail -> Task<T, Never> in
                let previous = tail
                let next = Task {
                    await previous?.value
                    return await operation()
                }
                tail = Task { _ = await next.value }
                return next
            }
            return await task.value
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
        engineFactory: (@Sendable (KinhinConfig) throws -> FleetEngine)? = nil
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
            case .replaceGiteaToken, .replaceForgejoToken:
                // Gitea/Forgejo tokens are account tokens under the accounts
                // schema; the legacy RPC cases stay on the wire but route to
                // the account swap by forge name.
                let account = request.method == .replaceGiteaToken ? ForgeID.gitea.rawValue : ForgeID.forgejo.rawValue
                guard let replacement = decodePayload(GiteaTokenReplaceRequest.self) else {
                    return RPCResponse(id: request.id, ok: false, error: "expected {\"token\": \"...\"}")
                }
                await engine.replaceToken(account: account, token: replacement.token)
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
                // Reloads are serialized: two overlapping rebuilds would each
                // detach the same engine and launch a replacement, leaving
                // an orphan engine driving the fleet. Each reload re-reads
                // the current engine once it holds the gate.
                return await engineRef.serialized {
                    await reload(request, engineRef: engineRef, configURL: configURL, engineFactory: engineFactory)
                }
            case .logs:
                let entries = Log.snapshot(limit: 300)
                return RPCResponse(id: request.id, ok: true, payload: try encoder.encode(entries))
            }
        } catch {
            return RPCResponse(id: request.id, ok: false, error: error.localizedDescription)
        }
    }

    /// Apply an edited config.yaml: routing-only edits apply live to the
    /// running engine; anything else (scope, bounds, VM shape, images,
    /// accounts) rebuilds the engine from the new file. Failure (bad YAML,
    /// validation) leaves the running fleet untouched on its current config.
    /// Callers hold `engineRef`'s serial gate.
    static func reload(
        _ request: RPCRequest,
        engineRef: EngineRef,
        configURL: URL,
        engineFactory: (@Sendable (KinhinConfig) throws -> FleetEngine)?
    ) async -> RPCResponse {
        guard let engine = engineRef.engine else {
            return RPCResponse(
                id: request.id, ok: false, error: "no engine (rebuild failed) — fix the config and edit again")
        }
        do {
            let cfg = try ConfigLoader.load(from: configURL)
            if FleetEngine.restartRequired(from: engine.activeConfig, to: cfg) {
                let replacement = try (engineFactory ?? Self.buildEngine)(cfg)
                let previous = await engine.status()
                let wasRunning = previous.running
                let wasPaused = previous.paused
                // A stopped fleet stays stopped across a rebuild — a
                // config edit must never start spawning VMs.
                if wasRunning {
                    // Verify the replacement's forges while the old
                    // engine still owns the fleet; nothing is adopted yet.
                    replacement.markRunning()
                    guard await replacement.prepareStart() else {
                        // Startup verification failed (bad PAT, transient
                        // network): keep the old engine serving instead
                        // of trading a running fleet for a dead one.
                        let error = await replacement.status().lastError ?? "startup verification failed"
                        Log.error("daemon", "rebuild did not start: \(error) — keeping the previous engine")
                        return RPCResponse(id: request.id, ok: false, error: "restart failed: \(error)")
                    }
                }
                // Detach (and drain) the old engine BEFORE the
                // replacement recovers, so no instance is driven by
                // two engines at once.
                await engine.detachKeepingInstances()
                if wasRunning {
                    await replacement.launch()
                    if wasPaused { await replacement.setPaused(true) }
                }
                engineRef.set(replacement)
                Log.info(
                    "daemon",
                    "config change required a restart — engine rebuilt (running: \(wasRunning), paused: \(wasPaused))"
                )
                return RPCResponse(id: request.id, ok: true)
            }
            engine.applyReloaded(config: cfg, host: ResourceProbe().snapshot())
            return RPCResponse(id: request.id, ok: true)
        } catch {
            return RPCResponse(id: request.id, ok: false, error: "reload failed: \(error.localizedDescription)")
        }
    }

    public struct VMDeleteRequest: Codable {
        public let id: String
        public init(id: String) { self.id = id }
    }

    enum DaemonError: LocalizedError, Equatable {
        case missingToken
        case alreadyRunning
        case lockFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingToken: return "no GitHub token stored — run `kinhin auth`"
            case .alreadyRunning: return "a daemon is already running"
            case .lockFailed(let why): return "could not take the daemon lock: \(why)"
            }
        }
    }
}
