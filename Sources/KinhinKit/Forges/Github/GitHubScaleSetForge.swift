import Foundation

// MARK: - Scale-set Forge adapter

/// One GitHub scale set the forge listens on. GitHub only lets a workflow
/// target a scale set by its name (`runs-on: kinhin-container`) — extra labels
/// are not kept on github.com — so each pool, and each named image, gets its
/// own set; the set a job arrives on tells kinhin where to run it.
struct ScaleSetTarget: Sendable {
    /// The scale-set name, i.e. the workflow's `runs-on:` value.
    let setName: String
    /// The pool this set feeds; nil only for a single-target forge built
    /// without routing information (jobs then route as classic ones do).
    let runtime: RuntimeID?
    /// Labels the runners of this set advertise (pool labels, plus a named
    /// image's): jobs from this set carry them, so image selection and pool
    /// markers keep working, and runner JIT configs are matched back by them.
    let routingLabels: [String]
    let listener: GitHubScaleSetListener
}

/// The `Forge` adapter for an account that opted into GitHub Runner Scale Set
/// mode. Demand comes from the scale-set message listener(s); everything else
/// (runners, deletion, pipeline detail/log, project file) is delegated to the
/// same REST `GitHubClient` path the classic poller uses.
struct GitHubScaleSetForge: ForgeWithQueuedJobs, ForgeWithJITConfig, ForgeWithListeners {
    let id: ForgeID = .github
    let name = "github"
    let account: String
    let labels: [String]
    let registration: ForgeRegistration = .jitConfig
    let exitSemantics: ForgeExitSemantics = .deregisters
    let credentials: ForgeCredentials

    let client: GitHubServing
    /// Every scale set this account listens on (first = the primary).
    let targets: [ScaleSetTarget]
    /// The primary listener (single-set accounts have only this one).
    var listener: GitHubScaleSetListener { targets[0].listener }
    /// One listener per scale set, started and stopped with the fleet.
    var listeners: [any ForgeListener] { targets.map(\.listener) }

    init(
        account: AccountConfig,
        token: String,
        client: GitHubServing,
        listener: GitHubScaleSetListener
    ) {
        self.init(account: account, token: token, client: client, labels: [], listener: listener)
    }

    /// A forge with one scale set and no routing information.
    init(
        account: AccountConfig,
        token: String,
        client: GitHubServing,
        labels: [String],
        listener: GitHubScaleSetListener
    ) {
        self.init(
            account: account, token: token, client: client, labels: labels,
            targets: [ScaleSetTarget(setName: "", runtime: nil, routingLabels: [], listener: listener)])
    }

    /// A forge listening on several scale sets (one per pool / named image).
    init(
        account: AccountConfig,
        token: String,
        client: GitHubServing,
        labels: [String],
        targets: [ScaleSetTarget]
    ) {
        precondition(!targets.isEmpty, "a scale-set forge needs at least one scale set")
        self.account = account.name
        self.credentials = .github(
            token: token, scope: account.scope,
            instance: account.instance, allowInsecureHTTP: account.allowInsecureHTTP ?? false)
        self.labels = account.labels ?? labels
        self.client = client
        self.targets = targets
    }

    private init(copying other: GitHubScaleSetForge, labels: [String]) {
        account = other.account
        credentials = other.credentials
        self.labels = labels
        client = other.client
        targets = other.targets
    }

    /// Demand arrives on the listeners, but running attribution filters by the
    /// fleet's labels (GitHub accounts carry no `labels:` of their own). The
    /// scale sets and their running listeners are kept as attached.
    func relabeled(fleetLabels: [String], servedLabels: [String]) -> any Forge {
        GitHubScaleSetForge(copying: self, labels: fleetLabels)
    }

    // MARK: - Registration URL (delegated to the underlying client path)

    func registrationURL() -> String {
        GitHubCredentials(token: "", scope: credentials.scope, instance: credentials.instance).configureURL
    }

    // MARK: - Registration (scale-set uses JIT config, not the shared token path)

    func mintRegistrationToken() async throws -> String {
        throw EngineError.scaleSetRegistrationUnsupported
    }

    func registrationTokens(runnerNames: [String], labels: [String]) async throws -> [String: String] {
        throw EngineError.scaleSetRegistrationUnsupported
    }

    // MARK: - Scale-set status: reaches through the listener

    func currentScaleSetId() async throws -> Int {
        try await listener.currentScaleSetId()
    }

    func scaleSetStatusMessage() async -> String {
        do {
            return "scale-set \(try await currentScaleSetId())"
        } catch {
            // Cosmetic: a status line. The listener's session refresh hits the same failure
            // and reports it (`reportedError`), so this only notes it for debugging.
            Log.debug("scaleset", "scale-set id unavailable for the status line: \(error.localizedDescription)")
            return "scale-set unknown"
        }
    }

    // MARK: - JIT config (per-runner)

    /// The scale set a runner with these labels must register in: the most
    /// specific one whose labels the runner carries (a named-image VM carries
    /// the pool's labels plus the image's, so it picks the image's set).
    func target(forRunnerLabels labels: [String]) -> ScaleSetTarget {
        guard targets.count > 1 else { return targets[0] }
        let have = Set(labels.map { $0.lowercased() })
        let matching = targets.filter { target in
            !target.routingLabels.isEmpty && Set(target.routingLabels.map { $0.lowercased() }).isSubset(of: have)
        }
        if let best = matching.max(by: { $0.routingLabels.count < $1.routingLabels.count }) { return best }
        Log.warn(
            "scaleset",
            "no scale set matches runner labels [\(labels.joined(separator: ", "))]; using '\(targets[0].setName)'")
        return targets[0]
    }

    func jitRunnerConfig(name: String, labels: [String]) async throws -> String? {
        do {
            let target = target(forRunnerLabels: labels)
            let id = try await target.listener.currentScaleSetId()
            let config = try await target.listener.generateJitConfig(
                scaleSetId: id, name: name, workFolder: "_work"
            )
            return config.encodedJitConfig
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EngineError.registrationFailed(vm: account, stderr: "JIT config: \(error.localizedDescription)")
        }
    }

    // MARK: - Demand: served from the listener snapshot

    func queuedJobs() async throws -> [ForgeJob] {
        // A single set without routing info behaves as before.
        if targets.count == 1, targets[0].runtime == nil { return try await targets[0].listener.queuedJobs() }
        var jobs: [ForgeJob] = []
        for target in targets {
            for job in try await target.listener.queuedJobs() {
                // The set a job arrived on is its `runs-on:` choice: stamp the
                // pool and the labels that pool/image routing keys on.
                jobs.append(
                    ForgeJob(
                        name: job.name, runnerName: job.runnerName, repository: job.repository,
                        labels: target.routingLabels, ref: job.ref, sha: job.sha, isFork: job.isFork,
                        forkKnown: job.forkKnown,
                        runtimeHint: target.runtime))
            }
        }
        return jobs
    }

    func runnersReportedFinished(_ names: [String]) async -> Set<String> {
        var finished: Set<String> = []
        for target in targets { finished.formUnion(await target.listener.finishedRunners(among: names)) }
        return finished
    }

    func pendingScaleSetError() async -> String? {
        for target in targets {
            if let message = await target.listener.reportedError()?.errorDescription {
                return targets.count > 1 && !target.setName.isEmpty ? "\(target.setName): \(message)" : message
            }
        }
        return nil
    }

    func scaleSetStatistics() async throws -> GitHubScaleSetStatistics {
        try await listener.scaleSetStatistics()
    }

    // MARK: - Runners / deletion: delegated to the existing GitHub REST path

    func runners() async throws -> [ForgeRunner] {
        try await client.listRunners().map { ForgeRunner(id: String($0.id), name: $0.name, busy: $0.busy) }
    }

    func deleteRunner(id: String) async throws {
        try await client.deleteRunner(id: try numericRunnerID(id))
    }

    // MARK: - Pipeline detail / log / project file: delegated unchanged

    func projectFile(repository: String, ref: String?) async throws -> Data? {
        try await client.projectFile(repository: repository, ref: ref)
    }

    func pipelineDetail(runnerName: String, repository: String?) async throws -> PipelineDetail? {
        try await client.pipelineDetail(runnerName: runnerName)
    }

    func pipelineLog(job: PipelineJob, step: PipelineStep?) async throws -> PipelineLog? {
        guard
            let ref = job.logRef,
            let bar = ref.lastIndex(of: "|"),
            let jobID = Int(ref[ref.index(after: bar)...]),
            let raw = try await client.jobLog(repository: String(ref[..<bar]), jobID: jobID)
        else { return nil }
        guard let step else {
            let (text, truncated) = PipelineLogText.clean(raw)
            return PipelineLog(text: text, scope: .job, truncated: truncated)
        }
        guard let index = job.steps.firstIndex(of: step) else { return nil }
        let (text, truncated) = PipelineLogText.clean(
            PipelineLogText.slice(jobLog: raw, steps: job.steps, index: index)
        )
        return PipelineLog(text: text, scope: .step, truncated: truncated)
    }

    // MARK: - Running jobs: delegated unchanged

    func runningJobs() async throws -> [ForgeJob] {
        try await client.runningJobs(matching: Set(labels)).map {
            ForgeJob(name: $0.name, runnerName: $0.runnerName, repository: $0.repository)
        }
    }

    // MARK: - Queue operations: unsupported

    // The listener yields `ForgeJob` demand without workflow-run ids, and the
    // REST cancel/skip calls need run ids. Rather than succeed silently (the
    // user would believe the queue was touched), report it through the normal
    // error path (`AlertKit` in the app, the RPC error for the CLI).

    func userRequeueQueuedJobs() async throws {
        throw GitHubError.scaleSetQueueActionUnsupported(action: "Requeueing queued jobs")
    }

    func userSkipQueuedJobs() async throws {
        throw GitHubError.scaleSetQueueActionUnsupported(action: "Skipping queued jobs")
    }
}
