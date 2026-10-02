import Foundation

// MARK: - Buildkite adapter

/// Forge implementation for Buildkite clusters.
///
/// Agents register with a cluster agent token, created when the forge is
/// built (Buildkite only reveals a token's value on creation, so each build
/// replaces the account's previous kinhin token). Each agent runs with
/// `--disconnect-after-job`, and the agent list only reports connected
/// agents, so the GitHub-style "every runner came and went" watch applies.
///
/// Jobs pick agents by agent query rules (`queue=…`, `os=…`): a job is
/// kinhin's demand when the account's labels, used as the agents' tags,
/// satisfy every rule. Demand and running attribution come from the
/// organization's active builds, narrowed to the cluster where the API says.
struct BuildkiteForge: Forge {
    let id: ForgeID = .buildkite
    let name = "buildkite"
    let account: String
    let credentials: ForgeCredentials
    /// The agents' tags, `key=value` (they include `queue=…`).
    let labels: [String]
    let registration: ForgeRegistration = .sharedLongLived
    let exitSemantics: ForgeExitSemantics = .deregisters
    let client: BuildkiteClient
    let cluster: BuildkiteCluster
    /// The cluster agent token captured at construction.
    let agentToken: String
    /// Every instance's exit watch lists agents each second; share the list.
    let agentList: SharedListCache<BuildkiteAgent>
    /// Queued and running jobs come from one builds read per poll.
    let jobList: SharedListCache<BuildkiteJob>

    /// Labels for an account that sets none: the `kinhin` queue.
    static let defaultLabels = ["queue=kinhin"]

    init(
        credentials: ForgeCredentials, labels: [String], client: BuildkiteClient, cluster: BuildkiteCluster,
        agentToken: String, account: String = "buildkite", listTTL: TimeInterval = 3
    ) {
        self.account = account
        self.credentials = credentials
        self.labels = labels
        self.client = client
        self.cluster = cluster
        self.agentToken = agentToken
        self.agentList = SharedListCache(ttl: listTTL)
        self.jobList = SharedListCache(ttl: listTTL)
    }

    /// Builds the forge: checks the token's scopes, resolves the cluster, and
    /// creates a fresh agent token after revoking the account's previous
    /// ones (registered agents keep their own session tokens).
    static func make(
        credentials: BuildkiteCredentials, labels: [String], account: String = "buildkite", session: URLSession? = nil
    ) async throws -> BuildkiteForge {
        let client = BuildkiteClient(credentials: credentials, session: session)
        try await client.verifyScopes()
        let cluster = try await client.resolveCluster()
        let description = agentTokenDescription(account: account)
        for stale in try await client.agentTokens(cluster: cluster) where stale.description == description {
            await bestEffortAsync("buildkite", "revoking the previous agent token of '\(account)'") {
                try await client.deleteAgentToken(cluster: cluster, id: stale.id)
            }
        }
        let token = try await client.createAgentToken(cluster: cluster, description: description)
        return BuildkiteForge(
            credentials: ForgeCredentials(forge: .buildkite, token: credentials.token, scope: credentials.scope),
            labels: labels, client: client, cluster: cluster, agentToken: token.token ?? "", account: account)
    }

    /// How kinhin names its agent tokens, so a rebuild finds and replaces them.
    static func agentTokenDescription(account: String) -> String {
        "kinhin: \(account)"
    }

    /// Pipelines across the organization feed one cluster.
    var attributesByRepo: Bool { true }

    /// Agents need no URL: the agent binary talks to Buildkite's agent API.
    func registrationURL() -> String {
        "https://agent.buildkite.com/v3"
    }

    func mintRegistrationToken() async throws -> String {
        agentToken
    }

    func runners() async throws -> [ForgeRunner] {
        try await agentList.elements { try await client.listAgents() }.map { agent in
            ForgeRunner(id: agent.id, name: agent.name, busy: agent.busy, online: agent.connectionState == "connected")
        }
    }

    func deleteRunner(id: String) async throws {
        defer { agentList.invalidate() }
        try await client.stopAgent(id: id)
    }

    func queuedJobs() async throws -> [ForgeJob] {
        try await jobs().filter { $0.isQueued && isOurs($0) }.map {
            ForgeJob(name: $0.name, runnerName: nil, repository: $0.pipeline, labels: $0.agentQueryRules)
        }
    }

    func runningJobs() async throws -> [ForgeJob] {
        try await jobs().filter { $0.isRunning && $0.agentName != nil && isOurs($0) }.map {
            ForgeJob(name: $0.name, runnerName: $0.agentName, repository: $0.pipeline, labels: $0.agentQueryRules)
        }
    }

    /// The build whose job `runnerName`'s agent is running, with every script
    /// job of the build. Buildkite's API exposes jobs, not steps within a job.
    func pipelineDetail(runnerName: String, repository: String?) async throws -> PipelineDetail? {
        let builds = try await client.activeBuilds()
        guard
            let build = builds.first(where: { build in
                build.jobs.contains { $0.type == "script" && $0.agent?.name == runnerName && $0.state == "running" }
            })
        else { return nil }
        let scripts = build.jobs.filter { $0.type == "script" }
        let mapped = scripts.map { job in
            PipelineJob(
                id: job.id, name: job.name ?? job.id, state: Self.state(job.state),
                startedAt: PipelineParsing.date(job.startedAt), finishedAt: PipelineParsing.date(job.finishedAt),
                url: job.webURL, isCurrent: job.agent?.name == runnerName,
                logRef: build.number.map { "\(build.pipeline.slug)|\($0)|\(job.id)" })
        }
        let number = build.number.map { " #\($0)" } ?? ""
        return PipelineDetail(
            forge: .buildkite, title: "\(build.pipeline.name ?? build.pipeline.slug)\(number)",
            repository: build.pipeline.slug, ref: build.branch, sha: build.commit, url: build.webURL,
            state: Self.state(build.state), startedAt: PipelineParsing.date(build.startedAt), jobs: mapped,
            granularity: .job)
    }

    /// A job's log; Buildkite has no steps below a job, so `step` is ignored.
    func pipelineLog(job: PipelineJob, step: PipelineStep?) async throws -> PipelineLog? {
        let parts = job.logRef?.split(separator: "|", omittingEmptySubsequences: false).map(String.init) ?? []
        guard parts.count == 3, let build = Int(parts[1]) else { return nil }
        let raw = try await client.jobLog(pipeline: parts[0], build: build, job: parts[2])
        let (text, truncated) = PipelineLogText.clean(raw)
        return PipelineLog(text: text, scope: .job, truncated: truncated)
    }

    static func state(_ state: String?) -> PipelineStepState {
        switch state ?? "" {
        case "running", "failing", "canceling": return .running
        case "passed", "finished": return .succeeded
        case "failed", "timed_out", "expired": return .failed
        case "canceled": return .cancelled
        case "skipped", "broken", "not_run", "blocked": return .skipped
        default: return .pending  // scheduled, assigned, accepted, waiting, limited
        }
    }

    private func jobs() async throws -> [BuildkiteJob] {
        try await jobList.elements { try await client.activeJobs() }
    }

    /// A job is this fleet's when it is not in another cluster and the
    /// account's labels satisfy its agent query rules.
    func isOurs(_ job: BuildkiteJob) -> Bool {
        if let clusterID = job.clusterID, clusterID != cluster.id { return false }
        return Self.tags(labels, satisfy: job.agentQueryRules)
    }

    // MARK: - Agent query rules

    /// Whether agents tagged `tags` (`key=value`) can take a job with these
    /// rules. Every rule must match a tag with the same key; `*` in a rule's
    /// value is a wildcard. A job without a `queue` rule targets the
    /// cluster's default queue, `queue=default`.
    static func tags(_ tags: [String], satisfy rules: [String]) -> Bool {
        var values: [String: String] = [:]
        for tag in tags {
            guard let (key, value) = split(tag) else { continue }
            values[key] = value
        }
        var required = rules.compactMap(split)
        if !required.contains(where: { $0.key == "queue" }) {
            required.append((key: "queue", value: "default"))
        }
        return required.allSatisfy { rule in
            guard let value = values[rule.key] else { return false }
            return matches(value, pattern: rule.value)
        }
    }

    /// `key=value` → its parts; nil for a malformed tag or rule.
    static func split(_ pair: String) -> (key: String, value: String)? {
        guard let equals = pair.firstIndex(of: "=") else { return nil }
        let key = pair[..<equals].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces))
    }

    /// Glob match where `*` stands for any run of characters.
    static func matches(_ value: String, pattern: String) -> Bool {
        guard pattern.contains("*") else { return value == pattern }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var rest = Substring(value)
        for (index, part) in parts.enumerated() {
            if index == 0 {
                guard rest.hasPrefix(part) else { return false }
                rest = rest.dropFirst(part.count)
            } else if index == parts.count - 1 {
                return part.isEmpty || rest.hasSuffix(part)
            } else if let range = rest.range(of: part) {
                rest = rest[range.upperBound...]
            } else {
                return false
            }
        }
        return true
    }
}
