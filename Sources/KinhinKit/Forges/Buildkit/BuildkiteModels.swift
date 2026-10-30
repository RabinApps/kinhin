import Foundation

// MARK: - Credentials

/// One Buildkite organization and cluster: `scope` is `org/cluster`, where
/// the cluster is named by its name or UUID (`BuildkiteClient.resolveCluster`
/// looks it up). Buildkite is hosted only, so there is no instance URL.
public struct BuildkiteCredentials: Sendable {
    public static let apiBase = "https://api.buildkite.com"

    public let token: String
    public let scope: String

    public init(token: String, scope: String) {
        self.token = token
        self.scope = scope
    }

    /// The organization slug (before the first slash).
    var organization: String {
        String(scope.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    /// The cluster name or UUID (after the first slash).
    var cluster: String {
        let parts = scope.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 ? String(parts[1]) : ""
    }

    /// `org/cluster`: a slug (lowercase letters, digits, `-`) and a
    /// non-empty cluster name or UUID, which may contain spaces.
    static func isValidScope(_ scope: String) -> Bool {
        let parts = scope.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let slug = parts[0]
        return !slug.isEmpty && slug.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
    }

    /// The token scopes the fleet needs: list and stop agents, read builds
    /// for demand, and mint the cluster's agent registration token.
    static let requiredScopes = ["read_agents", "write_agents", "read_builds", "read_clusters", "write_clusters"]
}

// MARK: - Wire models

/// A cluster, as `GET …/clusters` reports it.
struct BuildkiteCluster: Decodable, Sendable, Equatable {
    let id: String
    let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A queue of a cluster: agents join it with the `queue=<key>` tag.
struct BuildkiteQueue: Decodable, Sendable, Equatable {
    let id: String
    let key: String
}

/// A cluster agent token as created (`token` is only present on creation)
/// or listed.
struct BuildkiteAgentToken: Decodable, Sendable, Equatable {
    let id: String
    let description: String?
    let token: String?
}

/// A connected (or stopping) agent. `GET …/agents` omits agents that have
/// disconnected, so an agent started with `--disconnect-after-job` drops out
/// of the list once its job is done.
public struct BuildkiteAgent: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let connectionState: String?
    /// The job the agent is running, if any.
    let job: JobRef?
    /// The agent's tags, `key=value`.
    public let metaData: [String]

    struct JobRef: Decodable, Sendable, Equatable {
        let id: String
    }

    public var busy: Bool { job != nil }

    init(
        id: String, name: String, connectionState: String? = "connected", jobID: String? = nil, metaData: [String] = []
    ) {
        self.id = id
        self.name = name
        self.connectionState = connectionState
        self.job = jobID.map(JobRef.init(id:))
        self.metaData = metaData
    }

    enum CodingKeys: String, CodingKey {
        case id, name, job
        case connectionState = "connection_state"
        case metaData = "meta_data"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        connectionState = try container.decodeIfPresent(String.self, forKey: .connectionState)
        job = try container.decodeIfPresent(JobRef.self, forKey: .job)
        metaData = try container.decodeIfPresent([String].self, forKey: .metaData) ?? []
    }
}

/// A build with its jobs, as `GET …/builds` reports it.
struct BuildkiteBuild: Decodable, Sendable, Equatable {
    let pipeline: Pipeline
    let jobs: [Job]
    /// Shown by the app's pipeline view; absent from older fixtures.
    let number: Int?
    let state: String?
    let webURL: String?
    let branch: String?
    let commit: String?
    let startedAt: String?

    enum CodingKeys: String, CodingKey {
        case pipeline, jobs, number, state, branch, commit
        case webURL = "web_url"
        case startedAt = "started_at"
    }

    struct Pipeline: Decodable, Sendable, Equatable {
        let slug: String
        let name: String?
    }

    /// A build step. Only `script` jobs run on agents; waiters, block and
    /// trigger steps carry no agent demand.
    struct Job: Decodable, Sendable, Equatable {
        let id: String
        let type: String
        let name: String?
        let state: String?
        let agentQueryRules: [String]
        let agent: Agent?
        /// The cluster the job runs in, when the API reports it.
        let clusterID: String?
        let webURL: String?
        let startedAt: String?
        let finishedAt: String?
        /// When the job became runnable (it waits for an agent from then), when it was created, and its exit code.
        let runnableAt: String?
        let createdAt: String?
        let exitStatus: Int?

        struct Agent: Decodable, Sendable, Equatable {
            let name: String?
        }

        enum CodingKeys: String, CodingKey {
            case id, type, name, state, agent
            case webURL = "web_url"
            case startedAt = "started_at"
            case finishedAt = "finished_at"
            case runnableAt = "runnable_at"
            case createdAt = "created_at"
            case exitStatus = "exit_status"
            case agentQueryRules = "agent_query_rules"
            case clusterID = "cluster_id"
        }

        init(
            id: String, type: String = "script", name: String?, state: String?, agentQueryRules: [String] = [],
            agentName: String? = nil, clusterID: String? = nil
        ) {
            self.id = id
            self.type = type
            self.name = name
            self.state = state
            self.agentQueryRules = agentQueryRules
            self.agent = agentName.map { Agent(name: $0) }
            self.clusterID = clusterID
            self.webURL = nil
            self.startedAt = nil
            self.finishedAt = nil
            self.runnableAt = nil
            self.createdAt = nil
            self.exitStatus = nil
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            type = try container.decode(String.self, forKey: .type)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            state = try container.decodeIfPresent(String.self, forKey: .state)
            agentQueryRules = try container.decodeIfPresent([String].self, forKey: .agentQueryRules) ?? []
            agent = try container.decodeIfPresent(Agent.self, forKey: .agent)
            clusterID = try container.decodeIfPresent(String.self, forKey: .clusterID)
            webURL = try container.decodeIfPresent(String.self, forKey: .webURL)
            startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
            finishedAt = try container.decodeIfPresent(String.self, forKey: .finishedAt)
            runnableAt = try container.decodeIfPresent(String.self, forKey: .runnableAt)
            createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
            exitStatus = try container.decodeIfPresent(Int.self, forKey: .exitStatus)
        }
    }
}

/// A script job waiting for or running on an agent, attributed to its
/// pipeline.
public struct BuildkiteJob: Sendable, Equatable {
    public let id: String
    public let name: String
    public let state: String
    /// `key=value` rules an agent's tags must satisfy (`queue=…` included).
    public let agentQueryRules: [String]
    /// The pipeline slug.
    public let pipeline: String
    /// The agent running the job (running jobs only).
    public let agentName: String?
    let clusterID: String?
    /// The build the job belongs to, and when the job became runnable and started (telemetry only).
    let buildNumber: Int?
    let enqueuedAt: Date?
    let startedAt: Date?

    init(
        id: String, name: String, state: String, agentQueryRules: [String], pipeline: String,
        agentName: String?, clusterID: String? = nil, buildNumber: Int? = nil, enqueuedAt: Date? = nil,
        startedAt: Date? = nil
    ) {
        self.buildNumber = buildNumber
        self.enqueuedAt = enqueuedAt
        self.startedAt = startedAt
        self.id = id
        self.name = name
        self.state = state
        self.agentQueryRules = agentQueryRules
        self.pipeline = pipeline
        self.agentName = agentName
        self.clusterID = clusterID
    }

    /// Waiting for an agent.
    var isQueued: Bool { state == "scheduled" }
    /// Handed to an agent and not finished yet.
    var isRunning: Bool { ["assigned", "accepted", "running"].contains(state) }
}

// MARK: - Errors

/// Buildkite-specific failures. The HTTP-shaped API errors (401/403/404/5xx,
/// decoding) come from the shared transport as `ForgeAPIError`.
enum BuildkiteError: LocalizedError, Equatable {
    case invalidScope(String)
    case clusterNotFound(organization: String, cluster: String)
    case insufficientScopes([String])
    /// The agents' `queue=` tag names a queue the cluster does not have.
    case queueNotFound(cluster: String, queue: String, available: [String])
    /// A pagination link that leaves the Buildkite API host (or is not https).
    case untrustedPageLink(String)

    var errorDescription: String? {
        switch self {
        case .invalidScope(let scope):
            return "invalid Buildkite scope '\(scope)': use 'org-slug/cluster' (the cluster's name or id)"
        case .clusterNotFound(let organization, let cluster):
            return "no cluster '\(cluster)' in the Buildkite organization '\(organization)'"
        case .untrustedPageLink(let link):
            return "Buildkite returned a pagination link outside its API (\(link)); refusing to send the token there"
        case .queueNotFound(let cluster, let queue, let available):
            let known = available.isEmpty ? "it has none" : "it has: \(available.joined(separator: ", "))"
            return "the Buildkite cluster '\(cluster)' has no queue '\(queue)' (\(known)); "
                + "set the account's labels to `queue=<key>` of an existing queue"
        case .insufficientScopes(let missing):
            return "the Buildkite token is missing scopes: \(missing.joined(separator: ", ")). "
                + "It needs \(BuildkiteCredentials.requiredScopes.joined(separator: ", "))"
        }
    }
}

extension BuildkiteJob {
    /// The identifiers and provider timestamps of this job, for telemetry. The pipeline slug stands in for both the
    /// repository and the workflow name (Buildkite has no repository dimension of its own at this level).
    var correlation: JobCorrelation {
        JobCorrelation(
            runID: buildNumber.map(String.init), jobID: id, workflow: pipeline, jobName: name, repository: pipeline,
            enqueuedAt: enqueuedAt, startedAt: startedAt)
    }
}
