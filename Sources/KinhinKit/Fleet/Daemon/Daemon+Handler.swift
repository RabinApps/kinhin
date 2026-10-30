import Foundation

extension Daemon {
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
        engineFactory: (@Sendable (KinhinConfig) throws -> FleetEngine)? = nil,
        benchmarks: BenchmarkRegistry = .shared,
        holdsGate: Bool = false
    ) async -> RPCResponse {
        // Everything that changes the fleet runs through the same FIFO gate
        // as a reload: a start/stop/pause/delete landing mid-rebuild would
        // otherwise act on the engine being detached while the replacement
        // never saw it. Reads (status, pipeline, logs, ping) stay concurrent.
        if !holdsGate, request.method.mutatesFleet {
            return await engineRef.serialized {
                await handle(
                    request, engineRef: engineRef, configURL: configURL, engineFactory: engineFactory,
                    benchmarks: benchmarks, holdsGate: true)
            }
        }
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
                return RPCResponse(id: request.id, ok: true, payload: try encoder.encode(PingReply()))
            case .status:
                // No payload (older clients) means the full status with usage.
                let includeUsage = decodePayload(StatusRequest.self)?.includeUsage ?? true
                let status = await engine.status(includeUsage: includeUsage)
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
                try await engine.deleteVM(id: id)
                return RPCResponse(id: request.id, ok: true)
            case .pipelineDetail:
                guard let id = decodePayload(VMDeleteRequest.self)?.id else {
                    return RPCResponse(id: request.id, ok: false, error: "expected {\"id\": \"...\"}")
                }
                // No job running is a valid answer: an ok response with no payload.
                let detail = try await engine.pipelineDetail(vmID: id)
                return RPCResponse(id: request.id, ok: true, payload: try detail.map { try encoder.encode($0) })
            case .requeueQueuedJobs:
                guard let ask = decodePayload(ForgeJobsRequest.self) else {
                    return RPCResponse(id: request.id, ok: false, error: "expected {\"forge\": \"github\"}")
                }
                try await engine.requeueQueuedJobs(for: ask.forge)
                return RPCResponse(id: request.id, ok: true)
            case .skipQueuedJobs:
                guard let ask = decodePayload(ForgeJobsRequest.self) else {
                    return RPCResponse(id: request.id, ok: false, error: "expected {\"forge\": \"github\"}")
                }
                try await engine.skipQueuedJobs(for: ask.forge)
                return RPCResponse(id: request.id, ok: true)
            case .pipelineLog:
                guard let ask = decodePayload(PipelineLogRequest.self) else {
                    return RPCResponse(
                        id: request.id, ok: false, error: "expected {\"id\": \"...\", \"jobID\": \"...\"}")
                }
                let log = try await engine.pipelineLog(vmID: ask.id, jobID: ask.jobID, stepIndex: ask.stepIndex)
                return RPCResponse(id: request.id, ok: true, payload: try log.map { try encoder.encode($0) })
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
                // Runs under the gate (see above): two overlapping rebuilds
                // would each detach the same engine and launch a replacement,
                // leaving an orphan engine driving the fleet. The engine was
                // resolved after the gate was acquired, so it is current.
                return await reload(request, engineRef: engineRef, configURL: configURL, engineFactory: engineFactory)
            case .benchStart:
                guard let options = decodePayload(BenchmarkOptions.self) else {
                    return RPCResponse(id: request.id, ok: false, error: "expected benchmark options")
                }
                // Starts detached and answers at once: a run outlives the RPC deadline. The run pauses and
                // resumes the fleet itself.
                let runID = try benchmarks.start(options: options, environment: engine.benchmarkEnvironment())
                return RPCResponse(id: request.id, ok: true, payload: try encoder.encode(BenchStartReply(runID: runID)))
            case .benchStatus:
                let ask = decodePayload(BenchStatusRequest.self)
                guard let status = benchmarks.status(runID: ask?.runID) else {
                    throw BenchmarkError.unknownRun(ask?.runID ?? "(none started)")
                }
                let benchEncoder = JSONEncoder()
                benchEncoder.dateEncodingStrategy = .iso8601
                return RPCResponse(id: request.id, ok: true, payload: try benchEncoder.encode(status))
            case .benchCancel:
                let ask = decodePayload(BenchStatusRequest.self)
                guard benchmarks.cancel(runID: ask?.runID) else {
                    throw BenchmarkError.unknownRun(ask?.runID ?? "(none running)")
                }
                return RPCResponse(id: request.id, ok: true)
            case .healingStatus:
                return RPCResponse(id: request.id, ok: true, payload: try encoder.encode(await engine.healingStatus()))
            case .healingApprove, .healingDismiss:
                guard let id = decodePayload(HealingEventRequest.self)?.id else {
                    return RPCResponse(id: request.id, ok: false, error: "expected {\"id\": \"...\"}")
                }
                if request.method == .healingApprove {
                    try await engine.approveHealing(id: id)
                } else {
                    try await engine.dismissHealing(id: id)
                }
                return RPCResponse(id: request.id, ok: true)
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
            // Telemetry settings apply in place (no engine rebuild): unchanged settings leave the exporters alone.
            await TelemetryService.shared.apply(cfg.telemetry)
            if FleetEngine.restartRequired(from: engine.activeConfig, to: cfg) {
                let replacement = try (engineFactory ?? Self.buildEngine)(cfg)
                switch await engine.handOver(to: replacement) {
                case .rejected(let error):
                    // Startup verification failed (bad PAT, transient
                    // network): the old engine keeps serving instead of
                    // trading a running fleet for a dead one.
                    Log.error("daemon", "rebuild did not start: \(error) — keeping the previous engine")
                    return RPCResponse(id: request.id, ok: false, error: "restart failed: \(error)")
                case .handedOver(let wasRunning, let wasPaused):
                    engineRef.set(replacement)
                    Log.info(
                        "daemon",
                        "config change required a restart — engine rebuilt (running: \(wasRunning), paused: \(wasPaused))"
                    )
                    return RPCResponse(id: request.id, ok: true)
                }
            }
            engine.applyReloaded(config: cfg, host: ResourceProbe().snapshot())
            return RPCResponse(id: request.id, ok: true)
        } catch {
            return RPCResponse(id: request.id, ok: false, error: "reload failed: \(error.localizedDescription)")
        }
    }
}
