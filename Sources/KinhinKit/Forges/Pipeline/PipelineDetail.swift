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
    /// Where the forge keeps this step's own output (opaque to everything but
    /// that forge); nil when the output is only available per job, or at all.
    public let logRef: String?

    public init(
        name: String, state: PipelineStepState, startedAt: Date? = nil, finishedAt: Date? = nil,
        logRef: String? = nil
    ) {
        self.name = name
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.logRef = logRef
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
    /// Where the forge keeps the job's output (opaque to everything but that
    /// forge); nil when it can't be read.
    public let logRef: String?

    public init(
        id: String, name: String, state: PipelineStepState, startedAt: Date? = nil, finishedAt: Date? = nil,
        url: String? = nil, steps: [PipelineStep] = [], isCurrent: Bool = false, logRef: String? = nil
    ) {
        self.logRef = logRef
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

// MARK: - Output

/// What a log covers.
public enum PipelineLogScope: String, Codable, Sendable, Equatable {
    case step
    case job
}

/// A step's (or job's) output so far, cleaned of terminal escapes and bounded
/// to its most recent part.
public struct PipelineLog: Codable, Sendable, Equatable {
    public let text: String
    public let scope: PipelineLogScope
    /// The output was longer than `PipelineLogText.limit` and its start is cut.
    public let truncated: Bool
    public let fetchedAt: Date

    public init(text: String, scope: PipelineLogScope, truncated: Bool = false, fetchedAt: Date = Date()) {
        self.text = text
        self.scope = scope
        self.truncated = truncated
        self.fetchedAt = fetchedAt
    }
}

// MARK: - Parsing helpers

enum PipelineParsing {
    /// ISO-8601 with or without fractional seconds (forges differ).
    static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        // Fractional seconds are the common shape in job logs; plain is the fallback.
        if string.utf8.contains(UInt8(ascii: ".")), let date = fractionalFormatter.date(from: string) { return date }
        return plainFormatter.date(from: string) ?? fractionalFormatter.date(from: string)
    }

    /// Shared formatters (allocating one per call was visible per log line).
    /// `ISO8601DateFormatter` is thread-safe for parsing.
    nonisolated(unsafe) private static let plainFormatter = ISO8601DateFormatter()
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

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
