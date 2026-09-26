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

    enum CodingKeys: String, CodingKey {
        case id, name, status, labels
        case runID = "run_id"
        case runnerName = "runner_name"
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

    public init(runID: Int, jobID: Int, name: String, labels: [String], repository: String? = nil) {
        self.runID = runID
        self.jobID = jobID
        self.name = name
        self.labels = labels
        self.repository = repository
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
