import Foundation

// MARK: - Azure DevOps adapter

/// Forge implementation for Azure Pipelines agent pools (Azure DevOps
/// Services or Azure DevOps Server).
///
/// Azure has no separate registration token: an agent registers with a
/// personal access token that can manage the pool, so the account's PAT is
/// the long-lived registration credential (it reaches the instance, which is
/// why the token should be a dedicated one with only the Agent Pools scope).
/// Each agent runs one job (`run.sh --once`) and then removes itself from the
/// pool (`config.sh remove`), so the GitHub-style "every runner came and
/// went" watch applies.
///
/// Jobs pick agents by demands. The account's labels are exported to the
/// agent as capabilities, and a queued request is kinhin's demand when its
/// demands include every label (`kinhin`, or `name -equals value` for a
/// `name=value` label). Without labels the pool is kinhin's alone and every
/// request in it counts.
struct AzureDevOpsForge: Forge {
    let id: ForgeID = .azuredevops
    let name = "azuredevops"
    let account: String
    let credentials: ForgeCredentials
    /// Capabilities the agents advertise: `name` or `name=value`.
    let labels: [String]
    let registration: ForgeRegistration = .sharedLongLived
    let exitSemantics: ForgeExitSemantics = .deregisters
    let client: AzureDevOpsClient
    let pool: AzureDevOpsPool
    /// Every instance's exit watch lists agents each second; share the list.
    let agentList: SharedListCache<AzureDevOpsAgent>
    /// Queued and running requests come from one read per poll.
    let requestList: SharedListCache<AzureDevOpsJobRequest>

    init(
        credentials: ForgeCredentials, labels: [String], client: AzureDevOpsClient, pool: AzureDevOpsPool,
        account: String = "azuredevops", listTTL: TimeInterval = 3
    ) {
        self.account = account
        self.credentials = credentials
        self.labels = labels
        self.client = client
        self.pool = pool
        self.agentList = SharedListCache(ttl: listTTL)
        self.requestList = SharedListCache(ttl: listTTL)
    }

    /// Builds the forge, resolving the pool up front (fails fast on a bad
    /// token, organization or pool, or a pool the token cannot manage).
    static func make(
        credentials: AzureDevOpsCredentials, labels: [String], account: String = "azuredevops",
        session: URLSession? = nil
    ) async throws -> AzureDevOpsForge {
        let client = AzureDevOpsClient(credentials: credentials, session: session)
        let pool = try await client.resolvePool()
        return AzureDevOpsForge(
            credentials: ForgeCredentials(
                forge: .azuredevops, token: credentials.token, scope: credentials.scope,
                instance: credentials.instance),
            labels: labels, client: client, pool: pool, account: account)
    }

    /// Pipelines across the organization's projects share one pool.
    var attributesByRepo: Bool { true }

    /// The organization URL agents register against.
    func registrationURL() -> String {
        var url = credentials.instance ?? ""
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    /// The PAT itself: agents register with it.
    func mintRegistrationToken() async throws -> String {
        credentials.token
    }

    func runners() async throws -> [ForgeRunner] {
        try await agentList.elements { try await client.listAgents(pool: pool) }.map { agent in
            ForgeRunner(id: String(agent.id), name: agent.name, busy: agent.busy, online: agent.status == "online")
        }
    }

    func deleteRunner(id: String) async throws {
        defer { agentList.invalidate() }
        try await client.deleteAgent(pool: pool, id: try numericRunnerID(id))
    }

    func queuedJobs() async throws -> [ForgeJob] {
        try await requests().filter { $0.isQueued && isOurs($0) }.map {
            ForgeJob(name: $0.jobName ?? "azure-job", runnerName: nil, repository: $0.pipeline, labels: $0.demands)
        }
    }

    func runningJobs() async throws -> [ForgeJob] {
        try await requests().filter { $0.isRunning && $0.reservedAgent?.name != nil && isOurs($0) }.map {
            ForgeJob(
                name: $0.jobName ?? "azure-job", runnerName: $0.reservedAgent?.name, repository: $0.pipeline,
                labels: $0.demands)
        }
    }

    /// The build `runnerName`'s agent is running a job of, from the build
    /// timeline: Job records are the jobs, their Task children the steps. The
    /// job-request → build link (`owner.id`, `scopeId`) is undocumented, so a
    /// request without it yields no detail.
    func pipelineDetail(runnerName: String, repository: String?) async throws -> PipelineDetail? {
        guard
            let request = try await requests().first(where: { $0.isRunning && $0.reservedAgent?.name == runnerName }),
            let buildID = request.buildOwner?.id, let project = request.scopeId
        else { return nil }
        let timeline = try await client.timeline(project: project, buildID: buildID)
        // Cosmetic header data: the timeline alone is enough to show the steps.
        let info = try? await client.build(project: project, buildID: buildID)
        let records = timeline.records
        let jobs = records.filter { $0.type == "Job" }.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
        let mapped = jobs.map { job -> PipelineJob in
            let steps = records.filter { $0.parentId == job.id && $0.type == "Task" }
                .sorted { ($0.order ?? 0) < ($1.order ?? 0) }
                .map {
                    PipelineStep(
                        name: $0.name ?? "task", state: Self.state(state: $0.state, result: $0.result),
                        startedAt: PipelineParsing.date($0.startTime), finishedAt: PipelineParsing.date($0.finishTime),
                        logRef: logRef($0, project: project, buildID: buildID))
                }
            let isCurrent = request.jobId.map { $0.caseInsensitiveCompare(job.id) == .orderedSame } ?? false
            return PipelineJob(
                id: job.id, name: job.name ?? "job", state: Self.state(state: job.state, result: job.result),
                startedAt: PipelineParsing.date(job.startTime), finishedAt: PipelineParsing.date(job.finishTime),
                steps: steps, isCurrent: isCurrent || job.workerName == runnerName,
                logRef: logRef(job, project: project, buildID: buildID))
        }
        guard !mapped.isEmpty else { return nil }
        return PipelineDetail(
            forge: .azuredevops,
            title: [info?.definition?.name ?? request.pipeline, info?.buildNumber.map { "#\($0)" }]
                .compactMap { $0 }.joined(separator: " "),
            repository: request.pipeline, ref: info?.sourceBranch, sha: info?.sourceVersion,
            url: info?.links?.web?.href, state: PipelineDetail.aggregate(mapped.map(\.state)),
            startedAt: mapped.compactMap(\.startedAt).min(), jobs: mapped, granularity: .step)
    }

    private func logRef(_ record: AzureDevOpsTimelineRecord, project: String, buildID: Int) -> String? {
        record.log?.id.map { "\(project)|\(buildID)|\($0)" }
    }

    /// A task's (or the whole job's) log from the build's log store.
    func pipelineLog(job: PipelineJob, step: PipelineStep?) async throws -> PipelineLog? {
        guard let ref = (step?.logRef ?? (step == nil ? job.logRef : nil)) else { return nil }
        let parts = ref.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let buildID = Int(parts[1]), let logID = Int(parts[2]) else { return nil }
        let raw = try await client.buildLog(project: parts[0], buildID: buildID, logID: logID)
        let (text, truncated) = PipelineLogText.clean(raw)
        return PipelineLog(text: text, scope: step == nil ? .job : .step, truncated: truncated)
    }

    static func state(state: String?, result: String?) -> PipelineStepState {
        switch (state ?? "").lowercased() {
        case "inprogress": return .running
        case "pending": return .pending
        default: break
        }
        switch (result ?? "").lowercased() {
        case "succeeded", "succeededwithissues": return .succeeded
        case "failed": return .failed
        case "canceled", "abandoned": return .cancelled
        case "skipped": return .skipped
        default: return .pending
        }
    }

    private func requests() async throws -> [AzureDevOpsJobRequest] {
        try await requestList.elements { try await client.jobRequests(pool: pool) }
    }

    /// A request is this fleet's when its demands include every label.
    func isOurs(_ request: AzureDevOpsJobRequest) -> Bool {
        Self.demands(request.demands, include: labels)
    }

    // MARK: - Demands

    /// Whether `demands` ask for every label: `name` matches a demand on that
    /// name (existence or any value); `name=value` matches `name -equals
    /// value`. Names compare case-insensitively, as Azure's do.
    static func demands(_ demands: [String], include labels: [String]) -> Bool {
        let parsed = demands.map(parse)
        return labels.allSatisfy { label in
            let parts = label.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = parts[0].lowercased()
            let value = parts.count == 2 ? parts[1] : nil
            return parsed.contains { demand in
                guard demand.name.lowercased() == name else { return false }
                guard let value else { return true }
                return demand.equals?.caseInsensitiveCompare(value) == .orderedSame
            }
        }
    }

    /// `name`, `name -equals value` or `name -<op> value` → its name and, for
    /// `-equals`, the value.
    static func parse(_ demand: String) -> (name: String, equals: String?) {
        let words = demand.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard let name = words.first else { return ("", nil) }
        guard words.count == 3, words[1].lowercased() == "-equals" else { return (name, nil) }
        return (name, words[2])
    }

    /// The environment an agent exports so it advertises the labels as
    /// capabilities: `name` → `name=true`, `name=value` as is.
    static func capabilityEnvironment(_ labels: [String]) -> [String] {
        labels.map { $0.contains("=") ? $0 : "\($0)=true" }
    }
}
