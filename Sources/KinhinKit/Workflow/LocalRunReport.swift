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

    public init(
        workflowPath: URL, workflowName: String, workingDirectory: String, startedAt: Date, finishedAt: Date,
        jobs: [LocalJobResult], notices: [String]
    ) {
        self.workflowPath = workflowPath
        self.workflowName = workflowName
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.jobs = jobs
        self.notices = notices
    }

    /// The overall verdict. `partial` is distinct from `succeeded`: everything
    /// that ran passed, but something was skipped as unsupported (a matrix job,
    /// a `uses:` action other than checkout, an `if:` outside the supported
    /// subset), so the run proves less than a pass on a real runner would.
    public enum Outcome: String, Sendable, Codable, Equatable {
        case succeeded
        case partial
        case failed
        case skipped
        case pending
    }

    enum CodingKeys: String, CodingKey {
        case workflowPath, workflowName, workingDirectory, startedAt, finishedAt, jobs, notices
        // Derived, encoded for `--json` consumers; ignored when decoding.
        case outcome, unsupportedSkips
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workflowPath, forKey: .workflowPath)
        try container.encode(workflowName, forKey: .workflowName)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(finishedAt, forKey: .finishedAt)
        try container.encode(jobs, forKey: .jobs)
        try container.encode(notices, forKey: .notices)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(unsupportedSkips, forKey: .unsupportedSkips)
    }

    public var failedJobs: Int { jobs.filter { $0.state == .failed || $0.state == .cancelled }.count }
    public var succeededJobs: Int { jobs.filter { $0.state == .succeeded }.count }

    /// Every job or step that was skipped because kinhin cannot run it, as
    /// "job" or "job / step" with the reason.
    public var unsupportedSkips: [String] { Self.unsupportedSkips(in: jobs) }

    static func unsupportedSkips(in jobs: [LocalJobResult]) -> [String] {
        jobs.flatMap { job -> [String] in
            var found: [String] = []
            if job.skippedAsUnsupported { found.append("\(job.id): \(job.notices.first ?? "skipped as unsupported")") }
            for step in job.steps where step.skippedAsUnsupported {
                found.append("\(job.id) / \(step.name): \(step.notices.first ?? "skipped as unsupported")")
            }
            return found
        }
    }

    public var outcome: Outcome {
        if failedJobs > 0 { return .failed }
        if !unsupportedSkips.isEmpty { return .partial }
        if succeededJobs == jobs.count, !jobs.isEmpty { return .succeeded }
        if jobs.isEmpty { return .pending }
        return .skipped
    }

    /// The coarse pipeline state shared with the app: a partial run is
    /// `skipped`, never `succeeded`.
    public var overallState: PipelineStepState {
        switch outcome {
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .pending: return .pending
        case .partial, .skipped: return .skipped
        }
    }
}

extension LocalRunReport {
    /// Decodes the stored fields; `outcome` and `unsupportedSkips` are derived.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            workflowPath: try container.decode(URL.self, forKey: .workflowPath),
            workflowName: try container.decode(String.self, forKey: .workflowName),
            workingDirectory: try container.decode(String.self, forKey: .workingDirectory),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            finishedAt: try container.decode(Date.self, forKey: .finishedAt),
            jobs: try container.decode([LocalJobResult].self, forKey: .jobs),
            notices: try container.decode([String].self, forKey: .notices))
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
    /// The whole job was skipped because kinhin cannot run it (a matrix job).
    public let skippedAsUnsupported: Bool

    public init(
        name: String, id: String? = nil, state: PipelineStepState, startedAt: Date?, finishedAt: Date?,
        duration: TimeInterval?, steps: [LocalStepResult], notices: [String] = [],
        skippedAsUnsupported: Bool = false
    ) {
        self.skippedAsUnsupported = skippedAsUnsupported
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
    /// Skipped because kinhin cannot run it (a `uses:` action other than
    /// checkout, or an `if:` outside the supported subset) — not a deliberate
    /// skip such as `if: false` or an earlier failure.
    public let skippedAsUnsupported: Bool

    public var id: String { name }

    public var outputText: String {
        output ?? ""
    }

    public init(
        name: String, state: PipelineStepState, startedAt: Date?, finishedAt: Date?, duration: TimeInterval?,
        output: String? = nil, notices: [String] = [], skippedAsUnsupported: Bool = false
    ) {
        self.skippedAsUnsupported = skippedAsUnsupported
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
    /// 0 for a clean pass; 1 for anything else. A partial run exits 1 too
    /// unless `lenient` accepts skipped-as-unsupported work as good enough.
    public func exitCode(lenient: Bool = false) -> Int32 {
        switch outcome {
        case .succeeded: return 0
        case .partial: return lenient ? 0 : 1
        case .failed, .skipped, .pending: return 1
        }
    }
}
