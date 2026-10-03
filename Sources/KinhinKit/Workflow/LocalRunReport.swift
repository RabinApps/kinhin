import Foundation

/// A finished local workflow run: the parsed document, the jobs that ran (or
/// were skipped), timestamps, bounded step output and per-item notices.
public struct LocalRunReport: Sendable, Codable, Equatable {
    public let workflowPath: URL
    public let workflowName: String
    public let workingDirectory: String
    public let startedAt: Date
    public let finishedAt: Date
    public let jobs: [LocalJobResult]
    public let notices: [String]

    public var failedJobs: Int { jobs.filter { $0.state == .failed || $0.state == .cancelled }.count }
    public var succeededJobs: Int { jobs.filter { $0.state == .succeeded }.count }
    public var overallState: PipelineStepState {
        if failedJobs > 0 { return .failed }
        if succeededJobs == jobs.count, !jobs.isEmpty { return .succeeded }
        if jobs.isEmpty { return .pending }
        return .skipped
    }
}

/// One job of a finished local run, with its steps and the state of each.
public struct LocalJobResult: Sendable, Codable, Equatable, Identifiable {
    public let name: String
    public let id: String
    public let state: PipelineStepState
    public let startedAt: Date?
    public let finishedAt: Date?
    public let duration: TimeInterval?
    public let steps: [LocalStepResult]
    public let notices: [String]

    public init(
        name: String, id: String? = nil, state: PipelineStepState, startedAt: Date?, finishedAt: Date?,
        duration: TimeInterval?, steps: [LocalStepResult], notices: [String] = []
    ) {
        self.name = name
        self.id = id ?? name
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.duration = duration
        self.steps = steps
        self.notices = notices
    }
}

/// One finished step: its state, timing, captured output and notices.
public struct LocalStepResult: Sendable, Codable, Equatable, Identifiable {
    public let name: String
    public let state: PipelineStepState
    public let startedAt: Date?
    public let finishedAt: Date?
    public let duration: TimeInterval?
    public let output: String?
    public let notices: [String]

    public var id: String { name }

    public var outputText: String {
        output ?? ""
    }

    public init(
        name: String, state: PipelineStepState, startedAt: Date?, finishedAt: Date?, duration: TimeInterval?,
        output: String? = nil, notices: [String] = []
    ) {
        self.name = name
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.duration = duration
        self.output = output
        self.notices = notices
    }
}

/// Events the runner emits while a workflow runs. The CLI streams these to
/// stdout/stderr and the app drives its live view.
public enum LocalRunEvent: Sendable, Equatable {
    case jobStarted(String)
    case jobFinished(String, state: PipelineStepState)
    case stepStarted(String)
    case stepFinished(String, state: PipelineStepState)
    case stepOutput(String, output: String)
    case stepNotice(String, notice: String)
    case stepSkipped(String, notice: String)
    case needSkipped(String)
    case matrixSkipped(String)
}

/// Aggregate helpers for a finished report, used in the CLI's summary.
extension LocalRunReport {
    public var exitCode: Int32 { overallState == .succeeded ? 0 : 1 }
}
