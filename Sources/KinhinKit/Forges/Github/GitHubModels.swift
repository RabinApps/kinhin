import Foundation

// Wire models for the GitHub REST API and the forge-neutral job/repo values
// built from them.

public struct GHLabel: Codable, Sendable, Equatable {
    public let name: String
}

public struct GHRunner: Codable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let status: String  // "online" | "offline"
    public let busy: Bool
    public let labels: [GHLabel]?

}

public struct GHJob: Codable, Sendable, Equatable {
    public let id: Int
    let runID: Int
    public let name: String
    public let status: String
    public let labels: [String]?
    /// The runner executing (or slated to execute) this job — the key that
    /// maps a running job back to one of our VMs.
    let runnerName: String?
    /// Detail the jobs payload already carries; nil on payloads without it.
    let conclusion: String?
    let htmlURL: String?
    let startedAt: String?
    let workflowName: String?
    let steps: [GHStep]?

    enum CodingKeys: String, CodingKey {
        case id, name, status, labels, conclusion, steps
        case runID = "run_id"
        case runnerName = "runner_name"
        case htmlURL = "html_url"
        case startedAt = "started_at"
        case workflowName = "workflow_name"
    }
}

/// One step of a job, as the jobs endpoint reports it.
public struct GHStep: Codable, Sendable, Equatable {
    public let name: String
    public let status: String
    public let conclusion: String?
    public let number: Int?
    let startedAt: String?
    let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case name, status, conclusion, number
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

/// A job currently executing on a runner (per-repo attribution of running
/// work in org scope). `runnerName` is what the runner registered as.
public struct RunningJob: Sendable, Equatable {
    public let name: String
    let runnerName: String?
    public let repository: String?

    public init(name: String, runnerName: String?, repository: String?) {
        self.name = name
        self.runnerName = runnerName
        self.repository = repository
    }
}

/// A queued job that this fleet could run.
public struct QueuedJob: Sendable, Equatable {
    let runID: Int
    let jobID: Int
    public let name: String
    public let labels: [String]
    /// Repository the job belongs to (always present in org scope; nil when
    /// the API response didn't include it).
    public let repository: String?
    /// Branch or tag of the run, its commit, and whether it is a fork's PR.
    public let ref: String?
    public let sha: String?
    public let isFork: Bool
    /// The run payload named both repositories, so `isFork` is a fact.
    public let forkKnown: Bool

    public init(
        runID: Int, jobID: Int, name: String, labels: [String], repository: String? = nil, ref: String? = nil,
        sha: String? = nil, isFork: Bool = false, forkKnown: Bool = false
    ) {
        self.runID = runID
        self.jobID = jobID
        self.name = name
        self.labels = labels
        self.repository = repository
        self.ref = ref
        self.sha = sha
        self.isFork = isFork
        self.forkKnown = forkKnown
    }
}

public struct RegistrationToken: Codable, Sendable, Equatable {
    public let token: String
    let expiresAt: Date
}

/// A repository visible to the stored token — one pickable target for the
/// onboarding repo step and the Config tab's repo picker.
public struct RepoRef: Sendable, Equatable, Identifiable {
    public let fullName: String
    let isPrivate: Bool
    /// nil when the API didn't say (old Gitea versions).
    let hasActionsEnabled: Bool?

    public var id: String { fullName }

    public init(fullName: String, isPrivate: Bool = false, hasActionsEnabled: Bool? = nil) {
        self.fullName = fullName
        self.isPrivate = isPrivate
        self.hasActionsEnabled = hasActionsEnabled
    }
}
