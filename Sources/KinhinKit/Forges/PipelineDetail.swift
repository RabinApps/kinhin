import Foundation

// MARK: - Pipeline detail

/// Where a step is in its run, normalized across forges.
public enum PipelineStepState: String, Codable, Sendable, Equatable {
    case pending
    case running
    case succeeded
    case failed
    case skipped
    case cancelled

    public var isFinished: Bool {
        switch self {
        case .pending, .running: return false
        case .succeeded, .failed, .skipped, .cancelled: return true
        }
    }
}

/// How fine-grained a forge's detail is: real steps within a job, or whole jobs
/// (forges whose API exposes no step list).
public enum PipelineGranularity: String, Codable, Sendable, Equatable {
    case step
    case job
}

public struct PipelineStep: Codable, Sendable, Equatable {
    public let name: String
    public let state: PipelineStepState
    public let startedAt: Date?
    public let finishedAt: Date?

    public init(name: String, state: PipelineStepState, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.name = name
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

/// One job of a pipeline with its steps. `steps` is empty on forges whose API
/// exposes no step list; the pipeline's `granularity` says so.
public struct PipelineJob: Codable, Sendable, Equatable, Identifiable {
    /// Stable within the pipeline (the forge's job id, else the name).
    public let id: String
    public let name: String
    public let state: PipelineStepState
    public let startedAt: Date?
    public let finishedAt: Date?
    /// The job's page on the forge, when the API gives one.
    public let url: String?
    public let steps: [PipelineStep]
    /// True for the job this VM's runner is executing.
    public let isCurrent: Bool

    public init(
        id: String, name: String, state: PipelineStepState, startedAt: Date? = nil, finishedAt: Date? = nil,
        url: String? = nil, steps: [PipelineStep] = [], isCurrent: Bool = false
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.url = url
        self.steps = steps
        self.isCurrent = isCurrent
    }
}

/// The live pipeline a VM's runner is part of, in a forge-neutral shape:
/// the pipeline's jobs (the VM's own flagged), each with its steps.
public struct PipelineDetail: Codable, Sendable, Equatable {
    public let forge: ForgeID
    /// The workflow / pipeline / build name.
    public let title: String
    public let repository: String?
    public let ref: String?
    public let sha: String?
    /// The run's page on the forge, when the API gives one.
    public let url: String?
    public let state: PipelineStepState
    public let startedAt: Date?
    public let jobs: [PipelineJob]
    /// `.step`: jobs carry steps. `.job`: the forge exposes jobs only.
    public let granularity: PipelineGranularity
    public let fetchedAt: Date

    public init(
        forge: ForgeID, title: String, repository: String? = nil, ref: String? = nil, sha: String? = nil,
        url: String? = nil, state: PipelineStepState, startedAt: Date? = nil, jobs: [PipelineJob],
        granularity: PipelineGranularity = .step, fetchedAt: Date = Date()
    ) {
        self.forge = forge
        self.title = title
        self.repository = repository
        self.ref = ref
        self.sha = sha
        self.url = url
        self.state = state
        self.startedAt = startedAt
        self.jobs = jobs
        self.granularity = granularity
        self.fetchedAt = fetchedAt
    }

    /// The job this VM is running (falls back to the first).
    public var currentJob: PipelineJob? { jobs.first(where: \.isCurrent) ?? jobs.first }

    /// The pipeline's state from its jobs: running while any runs or waits,
    /// failed/cancelled once finished with one, else succeeded.
    static func aggregate(_ states: [PipelineStepState]) -> PipelineStepState {
        if states.contains(.running) { return .running }
        if states.contains(.pending) { return states.contains(where: { $0.isFinished }) ? .running : .pending }
        if states.contains(.failed) { return .failed }
        if states.contains(.cancelled) { return .cancelled }
        return states.isEmpty ? .pending : .succeeded
    }
}

// MARK: - Parsing helpers

enum PipelineParsing {
    /// ISO-8601 with or without fractional seconds (forges differ).
    static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }

    /// The state for a status/conclusion pair as GitHub-style APIs report it.
    static func state(status: String?, conclusion: String?) -> PipelineStepState {
        switch (status ?? "").lowercased() {
        case "queued", "pending", "waiting", "requested": return .pending
        case "in_progress", "running": return .running
        default: break
        }
        return conclusionState(conclusion)
    }

    static func conclusionState(_ conclusion: String?) -> PipelineStepState {
        switch (conclusion ?? "").lowercased() {
        case "success", "succeeded", "passed": return .succeeded
        case "failure", "failed", "timed_out", "error", "errored", "startup_failure": return .failed
        case "skipped", "neutral": return .skipped
        case "cancelled", "canceled", "canceling", "aborted": return .cancelled
        default: return .pending
        }
    }
}
