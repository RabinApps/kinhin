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
    /// The label sets a job may carry all of to count as this fleet's (`demandLabelSets`): just `labels`, unless some
    /// pool registers x64 runners.
    let demandLabelSets: [Set<String>]
    let registration: ForgeRegistration = .sharedShortLived
    let exitSemantics: ForgeExitSemantics = .deregisters
    let client: GitHubServing

    init(
        credentials: ForgeCredentials, labels: [String], client: GitHubServing, account: String = "github",
        servedLabels: [String] = []
    ) {
        self.credentials = credentials
        self.labels = labels
        self.demandLabelSets = Self.demandLabelSets(fleetLabels: labels, servedLabels: servedLabels)
        self.client = client
        self.account = account
    }

    /// The label sets a queued or running job may carry all of to count as this fleet's: the fleet labels, and, when
    /// some pool registers x64 runners (`servedLabels` has `x64`: an amd64 Apple container pool, or Docker on amd64),
    /// the fleet labels with `arm64` swapped for `x64`, which is what those runners carry instead. Lowercased, as the
    /// forge compares labels; the single-set case keeps the client's exact match.
    static func demandLabelSets(fleetLabels: [String], servedLabels: [String]) -> [Set<String>] {
        let fleet = fleetLabels.map { $0.lowercased() }
        let arm64 = LinuxPlatform.arm64.runnerLabel
        let x64 = LinuxPlatform.amd64.runnerLabel
        guard fleet.contains(arm64), servedLabels.contains(where: { $0.lowercased() == x64 }) else {
            return [Set(fleet)]
        }
        return [Set(fleet), Set(fleet.filter { $0 != arm64 } + [x64])]
    }

    /// Whether a job with `labels` carries every label of one of `demandLabelSets`. With one set the client's own
    /// filter already decided, exactly as before x64 pools.
    func countsAsFleets(_ labels: [String]) -> Bool {
        guard demandLabelSets.count > 1 else { return true }
        let have = Set(labels.map { $0.lowercased() })
        return demandLabelSets.contains { $0.isSubset(of: have) }
    }

    /// The label filter to read queued and running jobs with: the fleet labels exactly, as before, with one demand
    /// set; with several, none (every job comes back and `countsAsFleets` picks).
    private var clientFilter: Set<String> { demandLabelSets.count > 1 ? [] : Set(labels) }

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
    init(
        account: AccountConfig, token: String, client: GitHubServing, labels: [String], servedLabels: [String] = []
    ) {
        self.init(
            credentials: .github(
                token: token, scope: account.scope,
                instance: account.instance, allowInsecureHTTP: account.allowInsecureHTTP ?? false),
            labels: labels, client: client,
            account: account.name, servedLabels: servedLabels)
    }

    /// Demand and running attribution filter by the fleet's labels (GitHub
    /// accounts carry no `labels:` of their own).
    func relabeled(fleetLabels: [String], servedLabels: [String]) -> any Forge {
        GitHubForge(
            credentials: credentials, labels: fleetLabels, client: client, account: account, servedLabels: servedLabels)
    }

    func registrationURL() -> String {
        client.configureURL
    }

    func mintRegistrationToken() async throws -> String {
        try await client.fetchRegistrationToken().token
    }

    /// GitHub reports `expires_at`; the cache follows it.
    func mintRegistrationTokenExpiring() async throws -> (token: String, expiresAt: Date?) {
        let minted = try await client.fetchRegistrationToken()
        return (minted.token, minted.expiresAt)
    }

    func runners() async throws -> [ForgeRunner] {
        try await client.listRunners().map { ForgeRunner(id: String($0.id), name: $0.name, busy: $0.busy) }
    }

    func deleteRunner(id: String) async throws {
        try await client.deleteRunner(id: try numericRunnerID(id))
    }

    func queuedJobs() async throws -> [ForgeJob] {
        try await client.queuedJobs(matching: clientFilter).filter { countsAsFleets($0.labels) }.map {
            ForgeJob(
                name: $0.name, runnerName: nil, repository: $0.repository, labels: $0.labels, ref: $0.ref,
                sha: $0.sha, isFork: $0.isFork, forkKnown: $0.forkKnown, correlation: $0.correlation)
        }
    }

    var rateLimit: ForgeRateLimit? { client.rateLimit }

    func projectFile(repository: String, ref: String?) async throws -> Data? {
        try await client.projectFile(repository: repository, ref: ref)
    }

    func pipelineDetail(runnerName: String, repository: String?) async throws -> PipelineDetail? {
        try await client.pipelineDetail(runnerName: runnerName)
    }

    func jobOutcome(for correlation: JobCorrelation) async throws -> JobOutcome? {
        guard let jobID = correlation.jobID.flatMap(Int.init) else { return nil }
        return try await client.jobOutcome(repository: correlation.repository, jobID: jobID)
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
        try await client.runningJobs(matching: clientFilter).filter { countsAsFleets($0.labels) }.map {
            ForgeJob(
                name: $0.name, runnerName: $0.runnerName, repository: $0.repository, correlation: $0.correlation)
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
