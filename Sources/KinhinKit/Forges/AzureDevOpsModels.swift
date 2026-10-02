import Foundation

// MARK: - Credentials

/// One Azure DevOps organization (or Azure DevOps Server collection) and one
/// of its agent pools. `instance` is the organization URL
/// (`https://dev.azure.com/acme`, or `https://tfs.example.com/tfs/DefaultCollection`);
/// `scope` is the pool name, which may contain spaces.
public struct AzureDevOpsCredentials: Sendable {
    public let token: String
    public let scope: String
    public let instance: String
    /// The account opted in to plain `http://` (`allow_insecure_http`): the
    /// token then travels in cleartext. Redirect and pagination host checks
    /// still apply.
    public let allowInsecureHTTP: Bool

    public init(token: String, scope: String, instance: String, allowInsecureHTTP: Bool = false) {
        self.token = token
        self.scope = scope
        self.instance = instance
        self.allowInsecureHTTP = allowInsecureHTTP
    }

    /// The pool name, trimmed.
    var pool: String { scope.trimmingCharacters(in: .whitespaces) }

    /// An http(s) organization or collection URL with a host. An `_apis`
    /// path is not allowed (the client appends it).
    static func validate(instance: String, allowInsecureHTTP: Bool = false) throws -> URL {
        guard let url = URL(string: instance),
            ForgeHTTP.permitsScheme(of: url, allowInsecureHTTP: allowInsecureHTTP),
            let host = url.host, !host.isEmpty,
            !url.path.split(separator: "/").contains("_apis")
        else {
            throw AzureDevOpsError.invalidInstance(instance)
        }
        return url
    }

    /// Any non-empty pool name.
    static func isValidScope(_ scope: String) -> Bool {
        !scope.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A label an agent can advertise as a capability (it becomes an
    /// environment variable): `name` or `name=value`, where the name is
    /// letters, digits and `_`, not starting with a digit.
    static func isValidLabel(_ label: String) -> Bool {
        let parts = label.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts.first ?? ""
        // The value is exported into the agent's environment: no control
        // characters (newlines, NUL) in it.
        if parts.count == 2, parts[1].unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return false
        }
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" }
    }
}

// MARK: - Wire models

/// Azure DevOps wraps lists as `{"count": n, "value": [...]}`.
struct AzureDevOpsList<Element: Decodable>: Decodable {
    let value: [Element]
}

/// An agent pool.
struct AzureDevOpsPool: Decodable, Sendable, Equatable {
    let id: Int
    let name: String
}

/// An agent in the pool, with the request it is running (when asked for).
public struct AzureDevOpsAgent: Decodable, Sendable, Equatable {
    public let id: Int
    public let name: String
    /// "online" or "offline".
    public let status: String?
    let assignedRequest: RequestRef?

    struct RequestRef: Decodable, Sendable, Equatable {
        let requestId: Int64
    }

    public var busy: Bool { assignedRequest != nil }

    init(id: Int, name: String, status: String? = "online", assignedRequestID: Int64? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.assignedRequest = assignedRequestID.map(RequestRef.init(requestId:))
    }
}

/// A job request in the pool: queued (no `assignTime`), running (assigned,
/// no `result`), or finished (`result` set).
public struct AzureDevOpsJobRequest: Decodable, Sendable, Equatable {
    public let requestId: Int64
    public let jobName: String?
    let assignTime: String?
    let result: String?
    let finishTime: String?
    /// Demands as the API reports them: `name`, or `name -equals value` (and
    /// other operators kinhin does not interpret).
    public let demands: [String]
    let reservedAgent: AgentRef?
    let definition: Owner?
    /// What the pipeline view needs to find the build's timeline: the job
    /// record's id, the project, and the owning build. Optional throughout,
    /// since API versions differ.
    let jobId: String?
    let scopeId: String?
    let buildOwner: BuildOwner?

    /// The request's owner: for pipeline runs, the build.
    struct BuildOwner: Decodable, Sendable, Equatable {
        let id: Int?
        let name: String?

        init(id: Int?, name: String?) {
            self.id = id
            self.name = name
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            // `id` is a number for builds; tolerate a numeric string.
            if let number = try? container.decodeIfPresent(Int.self, forKey: .id) {
                id = number
            } else {
                id = (try? container.decodeIfPresent(String.self, forKey: .id)).flatMap { Int($0) }
            }
            name = try? container.decodeIfPresent(String.self, forKey: .name)
        }

        private enum Keys: String, CodingKey { case id, name }
    }

    struct AgentRef: Decodable, Sendable, Equatable {
        let name: String?
    }

    struct Owner: Decodable, Sendable, Equatable {
        let name: String?
    }

    enum CodingKeys: String, CodingKey {
        case requestId, jobName, assignTime, result, finishTime, demands, reservedAgent, definition
        case jobId, scopeId
        case buildOwner = "owner"
    }

    init(
        requestId: Int64, jobName: String?, assignTime: String? = nil, result: String? = nil, demands: [String] = [],
        reservedAgent: String? = nil, definition: String? = nil
    ) {
        self.requestId = requestId
        self.jobName = jobName
        self.assignTime = assignTime
        self.result = result
        self.finishTime = nil
        self.demands = demands
        self.reservedAgent = reservedAgent.map { AgentRef(name: $0) }
        self.definition = definition.map { Owner(name: $0) }
        self.jobId = nil
        self.scopeId = nil
        self.buildOwner = nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decode(Int64.self, forKey: .requestId)
        jobName = try container.decodeIfPresent(String.self, forKey: .jobName)
        assignTime = try container.decodeIfPresent(String.self, forKey: .assignTime)
        result = try container.decodeIfPresent(String.self, forKey: .result)
        finishTime = try container.decodeIfPresent(String.self, forKey: .finishTime)
        reservedAgent = try container.decodeIfPresent(AgentRef.self, forKey: .reservedAgent)
        definition = try container.decodeIfPresent(Owner.self, forKey: .definition)
        jobId = try? container.decodeIfPresent(String.self, forKey: .jobId)
        scopeId = try? container.decodeIfPresent(String.self, forKey: .scopeId)
        buildOwner = try? container.decodeIfPresent(BuildOwner.self, forKey: .buildOwner)
        demands = try container.decodeIfPresent([Demand].self, forKey: .demands)?.map(\.text) ?? []
    }

    /// A demand arrives as a string (`"kinhin -equals true"`) or, in some
    /// API versions, as `{"name": …, "value": …}`.
    private struct Demand: Decodable {
        let text: String

        init(from decoder: Decoder) throws {
            if let string = try? decoder.singleValueContainer().decode(String.self) {
                text = string
                return
            }
            struct Object: Decodable {
                let name: String
                let value: String?
            }
            let object = try Object(from: decoder)
            text = object.value.map { "\(object.name) -equals \($0)" } ?? object.name
        }
    }

    /// Waiting for an agent.
    var isQueued: Bool { assignTime == nil && result == nil && finishTime == nil }
    /// Handed to an agent and not finished.
    var isRunning: Bool { assignTime != nil && result == nil && finishTime == nil }
    /// The pipeline the request belongs to.
    var pipeline: String? { definition?.name }
}

// MARK: - Build timeline

/// One record of `GET /{project}/_apis/build/builds/{id}/timeline`: a stage,
/// job or task (step). Records nest through `parentId`.
struct AzureDevOpsTimelineRecord: Decodable, Sendable, Equatable {
    let id: String
    let parentId: String?
    let type: String?
    let name: String?
    let state: String?
    let result: String?
    let order: Int?
    let startTime: String?
    let finishTime: String?
    let workerName: String?
}

struct AzureDevOpsTimeline: Decodable, Sendable, Equatable {
    let records: [AzureDevOpsTimelineRecord]
}

/// `GET /{project}/_apis/build/builds/{id}`: the fields the pipeline view shows.
struct AzureDevOpsBuildInfo: Decodable, Sendable, Equatable {
    let buildNumber: String?
    let sourceBranch: String?
    let sourceVersion: String?
    let definition: Definition?
    let links: Links?

    struct Definition: Decodable, Sendable, Equatable { let name: String? }
    struct Links: Decodable, Sendable, Equatable {
        let web: Link?
        struct Link: Decodable, Sendable, Equatable { let href: String? }
    }

    enum CodingKeys: String, CodingKey {
        case buildNumber, sourceBranch, sourceVersion, definition
        case links = "_links"
    }
}

// MARK: - Errors

enum AzureDevOpsError: LocalizedError, Equatable {
    case unauthorized
    case forbidden(String)
    case notFound(String)
    case http(Int, String)
    case decoding(String)
    case invalidInstance(String)
    case poolNotFound(String)
    case cannotManagePool(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Azure DevOps rejected the personal access token (401): expired, revoked, or for another "
                + "organization. Fix: kinhin auth set NAME with a new token"
        case .forbidden(let why):
            return "Azure DevOps forbidden (403): \(why). The token needs the Agent Pools (Read & manage) scope"
        case .notFound(let what):
            return "Azure DevOps returned 404 for \(what): check the organization URL"
        case .http(let code, let body):
            return "Azure DevOps HTTP \(code): \(body)"
        case .decoding(let why):
            return "Could not decode Azure DevOps response: \(why)"
        case .invalidInstance(let url):
            return "invalid Azure DevOps organization URL: \(url). Use https://dev.azure.com/ORG "
                + "(or your server's collection URL)"
        case .poolNotFound(let pool):
            return "no agent pool '\(pool)' in this organization (create it under Organization settings → Agent pools)"
        case .cannotManagePool(let pool):
            return "the token cannot manage the agent pool '\(pool)': it needs the Agent Pools (Read & manage) "
                + "scope and the Administrator role on the pool"
        }
    }
}
