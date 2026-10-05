import Foundation

// MARK: - GitHub adapter

/// Wraps the existing GitHubServing client in the unified Forge protocol.
/// No GitHub behavior changes.
struct GitHubForge: Forge {
    let id: ForgeID = .github
    let name = "github"
    let account: String
    let credentials: ForgeCredentials
    let labels: [String]
    let registration: ForgeRegistration = .sharedShortLived
    let exitSemantics: ForgeExitSemantics = .deregisters
    let client: GitHubServing

    init(credentials: ForgeCredentials, labels: [String], client: GitHubServing, account: String = "github") {
        self.credentials = credentials
        self.labels = labels
        self.client = client
        self.account = account
    }

    /// Build from a GitHubCredentials (the legacy single-forge path),
    /// keeping any enterprise instance the credentials carry.
    init(credentials: GitHubCredentials, labels: [String]) {
        self.init(
            credentials: .github(
                token: credentials.token, scope: credentials.scope,
                instance: credentials.instance, allowInsecureHTTP: credentials.allowInsecureHTTP),
            labels: labels,
            client: GitHubClient(credentials: credentials))
    }

    /// Build from an account config and token, wiring enterprise-instance fields
    /// through to both the wrapped `ForgeCredentials` and the underlying
    /// `GitHubClient` (the caller's client — it must already target the
    /// account's instance).
    init(account: AccountConfig, token: String, client: GitHubServing, labels: [String]) {
        self.init(
            credentials: .github(
                token: token, scope: account.scope,
                instance: account.instance, allowInsecureHTTP: account.allowInsecureHTTP ?? false),
            labels: labels, client: client,
            account: account.name)
    }

    func registrationURL() -> String {
        client.configureURL
    }

    func mintRegistrationToken() async throws -> String {
        try await client.fetchRegistrationToken().token
    }

    func runners() async throws -> [ForgeRunner] {
        try await client.listRunners().map { ForgeRunner(id: String($0.id), name: $0.name, busy: $0.busy) }
    }

    func deleteRunner(id: String) async throws {
        try await client.deleteRunner(id: try numericRunnerID(id))
    }

    func queuedJobs() async throws -> [ForgeJob] {
        try await client.queuedJobs(matching: Set(labels)).map {
            ForgeJob(
                name: $0.name, runnerName: nil, repository: $0.repository, labels: $0.labels, ref: $0.ref,
                sha: $0.sha, isFork: $0.isFork)
        }
    }

    var rateLimit: ForgeRateLimit? { client.rateLimit }

    func projectFile(repository: String, ref: String?) async throws -> Data? {
        try await client.projectFile(repository: repository, ref: ref)
    }

    func pipelineDetail(runnerName: String, repository: String?) async throws -> PipelineDetail? {
        try await client.pipelineDetail(runnerName: runnerName)
    }

    func pipelineLog(job: PipelineJob, step: PipelineStep?) async throws -> PipelineLog? {
        guard let ref = job.logRef, let bar = ref.lastIndex(of: "|"), let jobID = Int(ref[ref.index(after: bar)...]),
            let raw = try await client.jobLog(repository: String(ref[..<bar]), jobID: jobID)
        else { return nil }
        guard let step else {
            let (text, truncated) = PipelineLogText.clean(raw)
            return PipelineLog(text: text, scope: .job, truncated: truncated)
        }
        guard let index = job.steps.firstIndex(of: step) else { return nil }
        let (text, truncated) = PipelineLogText.clean(
            PipelineLogText.slice(jobLog: raw, steps: job.steps, index: index))
        return PipelineLog(text: text, scope: .step, truncated: truncated)
    }

    func runningJobs() async throws -> [ForgeJob] {
        try await client.runningJobs(matching: Set(labels)).map {
            ForgeJob(name: $0.name, runnerName: $0.runnerName, repository: $0.repository)
        }
    }
}

extension GitHubForge: ForgeWithQueuedJobs {
    func userRequeueQueuedJobs() async throws {
        let jobs = try await queuedJobs()
        guard let queued = jobs as? [QueuedJob] else { throw EngineError.queueOperationUnavailable }
        _ = try await client.cancelWorkflowRun(ids: queued.map { $0.runID })
    }

    func userSkipQueuedJobs() async throws {
        let jobs = try await queuedJobs()
        guard let queued = jobs as? [QueuedJob] else { throw EngineError.queueOperationUnavailable }
        _ = try await client.skipWorkflowRun(ids: queued.map { $0.runID })
    }
}
