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

    struct Pipeline: Decodable, Sendable, Equatable {
        let slug: String
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

        struct Agent: Decodable, Sendable, Equatable {
            let name: String?
        }

        enum CodingKeys: String, CodingKey {
            case id, type, name, state, agent
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

    init(
        id: String, name: String, state: String, agentQueryRules: [String], pipeline: String,
        agentName: String?, clusterID: String? = nil
    ) {
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

enum BuildkiteError: LocalizedError, Equatable {
    case unauthorized
    case forbidden(String)
    case notFound(String)
    case http(Int, String)
    case decoding(String)
    case invalidScope(String)
    case clusterNotFound(organization: String, cluster: String)
    case insufficientScopes([String])
    /// A pagination link that leaves the Buildkite API host (or is not https).
    case untrustedPageLink(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Buildkite rejected the API access token (401): expired, revoked, or mistyped. "
                + "Fix: kinhin auth set NAME with a new token"
        case .forbidden(let why):
            return "Buildkite forbidden (403): \(why). The token must belong to a member of the organization"
        case .notFound(let what):
            return "Buildkite returned 404 for \(what): check the organization slug and that the token can see it"
        case .http(let code, let body):
            return "Buildkite HTTP \(code): \(body)"
        case .decoding(let why):
            return "Could not decode Buildkite response: \(why)"
        case .invalidScope(let scope):
            return "invalid Buildkite scope '\(scope)': use 'org-slug/cluster' (the cluster's name or id)"
        case .clusterNotFound(let organization, let cluster):
            return "no cluster '\(cluster)' in the Buildkite organization '\(organization)'"
        case .untrustedPageLink(let link):
            return "Buildkite returned a pagination link outside its API (\(link)); refusing to send the token there"
        case .insufficientScopes(let missing):
            return "the Buildkite token is missing scopes: \(missing.joined(separator: ", ")). "
                + "It needs \(BuildkiteCredentials.requiredScopes.joined(separator: ", "))"
        }
    }
}
