import Foundation

// MARK: - Healing (the engine's side of `HealingAgent`)

extension FleetEngine: HealingActions {
    /// Setup checks the agent acts on: runtimes and images. Tokens come from the
    /// account alerts, and config/CLT/architecture problems stop a fleet long
    /// before it could heal anything.
    static let healingSetupChecks: Set<String> = [
        "tart", "tart-rollback", "image", "base-image", "container-cli", "container-kernel", "container-image",
        "docker-cli", "docker-image", "host-agent",
    ]

    // MARK: Public API

    /// The whole healing journal and policy (a status poll carries only its
    /// open entries and recent history).
    public func healingStatus() async -> HealingSnapshot {
        await healing.currentSnapshot()
    }

    /// Carries out a fix waiting for approval (in the background).
    public func approveHealing(id: String) async throws {
        try await healing.approve(id, actions: self)
    }

    /// Closes a pending or surfaced healing event.
    public func dismissHealing(id: String) async throws {
        try await healing.dismiss(id, actions: self)
    }

    /// Starts the agent's loop with the fleet (`launch()`).
    func startHealing() async {
        healing.startLoop { [weak self] in
            guard let self else { return false }
            await self.healing.pass(actions: self)
            return true
        }
        await healing.publish(self)
    }

    // MARK: Signals

    func healingSignals(now: Date) async -> [HealingSignal] {
        var signals: [HealingSignal] = []
        for alert in await statusBox.get().alerts ?? [] {
            if let signal = Self.healingSignal(fromAlert: alert) { signals.append(signal) }
        }
        signals += store.all.filter { $0.phase == .deleting && $0.error != nil }.map { record in
            HealingSignal(
                kind: .teardownStuck, subject: record.id,
                detail: "instance \(record.id) could not be removed: \(record.error ?? "unknown error")")
        }
        signals += await spawnFailureSignals(now: now)
        // The setup checklist spawns processes and reads the Keychain: run it once, then again only while it
        // reported problems (to see them fixed) or runners keep failing (to learn why), at most once a probeTTL.
        let cached = healing.cachedProbe("setup")
        if cached == nil || cached?.value.isEmpty == false || signals.contains(where: { $0.kind == .spawnFailures }) {
            signals += await healing.probe("setup", now: now) { await setupSignals() }
        }
        // One signal per problem: the first source wins.
        var seen: Set<String> = []
        return signals.filter { seen.insert($0.key).inserted }
    }

    /// The problems status alerts describe. The engine's own retries (spawn
    /// backoff, orphans) and the agent's own alert are not problems to heal
    /// from here.
    static func healingSignal(fromAlert alert: FleetStatusAlert) -> HealingSignal? {
        let source = alert.source
        let message = alert.message
        if source == "disk" { return HealingSignal(kind: .diskPressure, detail: message) }
        if source == "credentials" { return HealingSignal(kind: .credentials, detail: message) }
        if source == "reconcile" { return HealingSignal(kind: .reconcileFailing, detail: message) }
        if source.hasPrefix("account:") {
            let account = String(source.dropFirst("account:".count))
            return HealingSignal(
                kind: .accountDetached, subject: account, detail: message,
                evidence: looksLikeAuthFailure(message) ? .authRejected : nil)
        }
        if source.hasPrefix("queue:") {
            return HealingSignal(
                kind: .queueUnreadable, subject: String(source.dropFirst("queue:".count)), detail: message)
        }
        return nil
    }

    /// A forge answer that only a new token fixes.
    static func looksLikeAuthFailure(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["401", "403", "unauthorized", "forbidden", "bad credentials", "token", "authentication"]
            .contains { text.contains($0) }
    }

    /// Runtimes held back by the spawn backoff, with what their health probe says.
    func spawnFailureSignals(now: Date) async -> [HealingSignal] {
        let failing = spawnBackoff.withLock { backoff in
            backoff.entries.filter { $0.value.failures >= SpawnBackoff.threshold }
        }
        var signals: [HealingSignal] = []
        for (runtime, entry) in failing.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let detail = "\(runtime.rawValue) runners failed to start \(entry.failures) times: \(entry.lastReason)"
            let evidence = await healing.probeEvidence(runtime.rawValue, now: now) { await probeHealth(runtime) }
            signals.append(
                HealingSignal(kind: .spawnFailures, subject: runtime.rawValue, detail: detail, evidence: evidence))
        }
        return signals
    }

    /// What a runtime's prerequisites say about repeated spawn failures.
    func probeHealth(_ runtime: RuntimeID) async -> HealingSignal.Evidence? {
        if runtime == .tart {
            switch await healingHost.tartHealth(config) {
            case .healthy: return nil
            case .missing: return .runtimeMissing
            case .killedOnLaunch: return .tartKilledOnLaunch
            case .broken: return .tartBroken
            }
        }
        guard let instance = runtimesByRuntime[runtime] else { return nil }
        switch await instance.health() {
        case .ready: return nil
        case .missing: return .runtimeMissing
        case .broken(let reason):
            return runtime == .appleContainer && reason.contains("not running")
                ? .containerSystemStopped : .runtimeBroken
        }
    }

    /// Setup checks about tart and its images, which only matter to a fleet that runs Tart VMs.
    static let tartSetupChecks: Set<String> = ["tart", "tart-rollback", "image", "base-image"]

    /// Whether any work can land on Tart: it is the default pool, a route
    /// names it, or named images or a warm pool need it. (Explicit routing
    /// always lists a tart pool; that alone does not make a Docker fleet need tart.)
    var tartInUse: Bool {
        let snapshot = router.snapshot
        return snapshot.model.defaultRuntime == .tart || snapshot.model.routes.contains { $0.runtime == .tart }
            || !snapshot.images.isEmpty || config.warmPool > 0
    }

    func setupSignals() async -> [HealingSignal] {
        let tart = tartInUse
        return await healingHost.setupChecks(config)
            .filter { !$0.ok && $0.action != nil && Self.healingSetupChecks.contains($0.id) }
            .filter { tart || !Self.tartSetupChecks.contains($0.id) }
            .map { check in
                HealingSignal(
                    kind: .setupCheck, subject: check.id, detail: "\(check.title): \(check.detail)",
                    setupAction: check.action)
            }
    }

    // MARK: Context for the advisor

    func healingContext(for signal: HealingSignal) -> String {
        let entries = Log.snapshot(limit: 300).filter { entry in
            guard entry.level != "debug" else { return false }
            guard let subject = signal.subject else { return entry.level != "info" }
            return entry.component == subject || entry.message.contains(subject)
        }
        let lines = entries.suffix(40).map { "\($0.level) \($0.component): \($0.message)" }
        let text = LogRedactor.redact(lines.joined(separator: "\n"))
        // The on-device model's window is a few thousand tokens.
        return String(text.suffix(3000))
    }

    var healingPlaybookContext: HealingPlaybook.Context {
        HealingPlaybook.Context(cacheAutoPrune: ToolchainCachePolicy(from: config.toolchainCache).autoPrune)
    }

    // MARK: Fixes

    func perform(_ fix: Remediation) async throws -> String {
        switch fix.kind {
        case .recycleInstance:
            guard let id = fix.subject, store.all.contains(where: { $0.id == id }) else {
                return "the record was already gone"
            }
            await deleteVMRecord(id: id, reason: "healing: instance gone")
            if let left = store.all.first(where: { $0.id == id }) {
                throw EngineError.healingFailed("could not remove \(id): \(left.error ?? "teardown failed")")
            }
            pollSoon()
            return "removed \(id); a replacement starts if work is waiting"
        case .retryForgeAttach:
            await retryDetachedForgesNow()
            guard let account = fix.subject else { return "retried every detached account" }
            guard forges[account] != nil else {
                throw EngineError.healingFailed("account \(account) is still detached")
            }
            return "re-attached account \(account)"
        case .pruneToolchainCache:
            let detail = try await healingHost.pruneToolchainCache(config)
            await pruneProjectImages()
            return detail
        case .startContainerSystem:
            return try await healingHost.startContainerSystem()
        case .pruneImages:
            return try await healingHost.pruneImages(config, store.all)
        case .repairRuntime:
            guard let runtime = fix.subject.flatMap(RuntimeID.init(rawValue:)) else {
                throw EngineError.healingFailed("no runtime named for the repair")
            }
            return try await healingHost.repairRuntime(runtime)
        case .repairTart:
            return try await healingHost.repairTart(config)
        case .replaceToken, .prepareImage, .inspectInstance, .reviewSetup:
            throw EngineError.healingFailed("\(fix.summary) is yours to do; kinhin never does it on its own")
        }
    }

    // MARK: Publishing

    func publish(_ snapshot: HealingSnapshot, alert: String?) async {
        await statusBox.modify { status in
            status.healing = snapshot
            status.setAlert("healing", alert)
        }
    }
}
