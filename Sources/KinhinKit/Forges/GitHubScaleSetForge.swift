import Foundation

// MARK: - Scale-set Forge adapter

/// The `Forge` adapter for an account that opted into GitHub Runner Scale Set
/// mode. Demand comes from the scale-set message listener; everything else
/// (runners, deletion, pipeline detail/log, project file) is delegated to the
/// same REST `GitHubClient` path the classic poller uses.
///
/// This is the "adapter + listener addition" layer the scale-set plan describes,
/// on top of the existing GitHub poller path rather than a second full fork of
/// GitHubForge.
struct GitHubScaleSetForge: Forge, ForgeWithQueuedJobs {
    let id: ForgeID = .github
    let name = "github"
    let account: String
    let labels: [String]
    let registration: ForgeRegistration = .jitConfig
    let exitSemantics: ForgeExitSemantics = .deregisters
    let credentials: ForgeCredentials

    let client: GitHubServing
    let listener: GitHubScaleSetListener

    init(
        account: AccountConfig,
        token: String,
        client: GitHubServing,
        listener: GitHubScaleSetListener
    ) {
        self.account = account.name
        self.credentials = .github(token: token, scope: account.scope)
        self.labels = account.labels ?? []
        self.client = client
        self.listener = listener
    }

    init(
        account: AccountConfig,
        token: String,
        client: GitHubServing,
        labels: [String],
        listener: GitHubScaleSetListener
    ) {
        self.account = account.name
        self.credentials = .github(token: token, scope: account.scope)
        self.labels = account.labels ?? labels
        self.client = client
        self.listener = listener
    }

    /// Labels to pass through to the existing GitHub client paths. Scale-set
    /// mode still uses the fleet's configured labels for delegation purposes;
    /// the scale-set label routing itself lives in the listener/VM targeting
    /// layer.
    private static func clientLabels(for account: AccountConfig, existing client: GitHubServing) -> [String] {
        // The scale-set forge is built from an AccountConfig, not from
        // GitHubForge-style config.labels, so fall back to an empty label set
        // for the delegated REST paths until the per-pool label derivation is
        // wired.
        return []
    }

    // MARK: - Registration URL (delegated to the underlying client path)

    func registrationURL() -> String {
        GitHubCredentials(token: "", scope: credentials.scope).configureURL
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
        let id = (try? await currentScaleSetId()).map { String($0) } ?? "unknown"
        return "scale-set \(id)"
    }

    // MARK: - JIT config (per-runner)

    func jitRunnerConfig(name: String, labels: [String]) async throws -> String? {
        do {
            let id = try await listener.currentScaleSetId()
            let config = try await listener.generateJitConfig(
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
        try await listener.queuedJobs()
    }

    func pendingScaleSetError() async -> String? {
        (await listener.reportedError())?.errorDescription
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

    // MARK: - Queue operations: delegated to the underlying GitHub client

    func userRequeueQueuedJobs() async throws {
        // The listener produces `ForgeJob` demand; the underlying GitHub REST
        // path operates on queued workflow-run ids. Until the scale-set listener
        // emits run ids, this is intentionally a no-op.
    }

    func userSkipQueuedJobs() async throws {
        // The listener produces `ForgeJob` demand; the underlying GitHub REST
        // path operates on queued workflow-run ids. Until the scale-set listener
        // emits run ids, this is intentionally a no-op.
    }
}
