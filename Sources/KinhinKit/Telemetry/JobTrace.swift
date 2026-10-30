import Foundation
import Synchronization

/// What a forge told us about one job, forge-neutrally. Every field is optional: a forge fills
/// what its API exposes, and consumers use a value only when it is present (no fabricated times).
public struct JobCorrelation: Sendable, Equatable {
    public var runID: String?
    public var runAttempt: Int?
    public var jobID: String?
    public var workflow: String?
    public var jobName: String?
    public var repository: String?
    /// When the forge queued the job (GitHub: the job's `created_at`).
    public var enqueuedAt: Date?
    public var startedAt: Date?
    public var completedAt: Date?

    public init(
        runID: String? = nil, runAttempt: Int? = nil, jobID: String? = nil, workflow: String? = nil,
        jobName: String? = nil, repository: String? = nil, enqueuedAt: Date? = nil, startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.runID = runID
        self.runAttempt = runAttempt
        self.jobID = jobID
        self.workflow = workflow
        self.jobName = jobName
        self.repository = repository
        self.enqueuedAt = enqueuedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// What a forge reports about a finished job: its verdict, its own start and end times and its steps. Every field
/// is optional (a forge fills what its API exposes), and a nil result is "unknown", never a guess.
public struct JobOutcome: Sendable, Equatable {
    /// The `cicd.pipeline.result` values.
    public enum Result: String, Sendable, Equatable {
        case success, failure, cancellation, timeout, skip
    }

    public var result: Result?
    public var startedAt: Date?
    public var completedAt: Date?
    public var steps: [PipelineStep]

    public init(
        result: Result? = nil, startedAt: Date? = nil, completedAt: Date? = nil, steps: [PipelineStep] = []
    ) {
        self.result = result
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.steps = steps
    }

    /// Maps a GitLab job status (and, for `failed`, its failure reason); jobs that have not finished or are waiting
    /// on a person (`manual`) stay unknown.
    static func result(gitLabStatus status: String?, failureReason: String? = nil) -> Result? {
        switch status {
        case "success": return .success
        case "failed":
            return failureReason == "job_execution_timeout" || failureReason == "stuck_or_timeout_failure"
                ? .timeout : .failure
        case "canceled", "canceling": return .cancellation
        case "skipped": return .skip
        default: return nil
        }
    }

    /// Maps a Buildkite job state (REST API). A `finished` job's verdict is its exit status; one with no exit status
    /// stays unknown rather than being read as a pass.
    static func result(buildkiteState state: String?, exitStatus: Int?) -> Result? {
        switch state {
        case "passed": return .success
        case "failed": return .failure
        case "finished":
            guard let exitStatus else { return nil }
            return exitStatus == 0 ? .success : .failure
        case "timed_out", "expired": return .timeout
        case "canceled", "canceling": return .cancellation
        case "skipped", "broken": return .skip
        default: return nil
        }
    }

    /// Whether a Buildkite job state means the job is over.
    static func isFinished(buildkiteState state: String?) -> Bool {
        ["passed", "failed", "finished", "timed_out", "expired", "canceled", "skipped", "broken"]
            .contains(state ?? "")
    }

    /// Whether a GitLab job status means the job is over.
    static func isFinished(gitLabStatus status: String?) -> Bool {
        ["success", "failed", "canceled", "skipped"].contains(status ?? "")
    }

    /// Maps a Gitea or Forgejo task status. `unknown` is a task that never ran: finished, with no verdict.
    static func result(giteaStatus status: String?) -> Result? {
        switch status {
        case "success": return .success
        case "failure": return .failure
        case "cancelled": return .cancellation
        case "skipped": return .skip
        default: return nil
        }
    }

    /// Whether a Gitea or Forgejo task status means the task is over.
    static func isFinished(giteaStatus status: String?) -> Bool {
        ["success", "failure", "cancelled", "skipped", "unknown"].contains(status ?? "")
    }

    /// Maps an Azure DevOps job request result (`TaskResult`); a request with no result yet stays unknown. The API
    /// has no separate timeout result.
    static func result(azureResult result: String?) -> Result? {
        switch (result ?? "").lowercased() {
        case "succeeded", "succeededwithissues": return .success
        case "failed": return .failure
        case "canceled", "abandoned": return .cancellation
        case "skipped": return .skip
        default: return nil
        }
    }

    /// Maps a GitHub job conclusion; unrecognised values (`neutral`, `action_required`) stay unknown.
    static func result(gitHubConclusion conclusion: String?) -> Result? {
        switch conclusion {
        case "success": return .success
        case "failure": return .failure
        case "cancelled": return .cancellation
        case "timed_out": return .timeout
        case "skipped": return .skip
        default: return nil
        }
    }
}

/// The trace of one instance's job: a root span from spawn to teardown, with child spans for
/// the phases kinhin times itself (provision, boot, registration, run, teardown) and, when the
/// forge supplied timestamps, queue-wait and provider-reported steps. VM, run and job
/// identifiers live on the spans, never on metrics.
final class JobTrace: Sendable {
    private struct State {
        var root: any TelemetrySpan
        var open: [String: any TelemetrySpan] = [:]
        var correlation: JobCorrelation?
        /// Jobs already attached (a multi-runner instance carries several; the first owns the root span).
        var seenJobs: Set<String> = []
        var ended = false
    }

    private let telemetry: Telemetry
    private let state: Mutex<State>
    private let markers = Mutex(Markers())

    /// One-shot flags and the run's monotonic start, so each event is counted once.
    private struct Markers {
        var errorCounted = false
        var runStart: ContinuousClock.Instant?
        var runFinished = false
        var pickupCounted = false
    }
    let pool: String
    let image: String
    let forge: String
    /// The log context of this instance's lifecycle; its `job` follows the job the forge reports.
    let logContext: Log.Context

    init(telemetry: Telemetry, vm: String, pool: String, image: String, forge: String, labels: [String]?) {
        self.telemetry = telemetry
        self.pool = pool
        self.image = image
        self.forge = forge
        var attributes: TelemetryAttributes = [
            "kinhin.vm.id": .string(vm), "kinhin.runner.name": .string(vm), Metric.Attr.pool: .string(pool),
            Metric.Attr.image: .string(image), Metric.Attr.forge: .string(forge),
        ]
        if let labels, !labels.isEmpty {
            attributes[Metric.Attr.labels] = .string(labels.sorted().joined(separator: ","))
        }
        let root = telemetry.startSpan("kinhin.job", attributes: attributes)
        state = Mutex(State(root: root))
        logContext = Log.Context(vm: vm, trace: root.context)
    }

    var context: TelemetrySpanContext? { state.withLock { $0.root.context } }

    /// Begins a measured child span; the phase's name is the span's name.
    func begin(_ phase: Metric.Phase) {
        state.withLock { state in
            guard !state.ended, state.open[phase.rawValue] == nil else { return }
            state.open[phase.rawValue] = state.root.startChild(phase.rawValue)
        }
    }

    func end(_ phase: Metric.Phase, at: Date? = nil, error: String? = nil) {
        let span = state.withLock { $0.open.removeValue(forKey: phase.rawValue) }
        span?.end(at: at, error: error)
    }

    /// The forge's verdict, on the root span as `cicd.pipeline.result`.
    func setResult(_ result: String) {
        let root = state.withLock { $0.ended ? nil : $0.root }
        root?.setAttributes([Metric.Attr.result: .string(result)])
    }

    /// Records the forge's view of the job once it is known: root attributes, plus a
    /// queue-wait span when the forge gave both its queue and start times. Returns the
    /// queue wait in seconds when it is a real interval. Idempotent per job id.
    @discardableResult
    func attach(_ correlation: JobCorrelation) -> Double? {
        enum Role { case first, additional, seen }
        let role: Role = state.withLock { state in
            guard !state.ended else { return .seen }
            if state.correlation == nil {
                state.correlation = correlation
                state.seenJobs.insert(Self.key(correlation))
                return .first
            }
            return state.seenJobs.insert(Self.key(correlation)).inserted ? .additional : .seen
        }
        if let name = correlation.jobName { logContext.job = name }
        if let id = correlation.jobID { logContext.jobID = id }
        if role == .additional { return attachAdditional(correlation) }
        guard role == .first else { return nil }
        var attributes: TelemetryAttributes = [:]
        if let value = correlation.runID { attributes["cicd.pipeline.run.id"] = .string(value) }
        if let value = correlation.runAttempt { attributes["kinhin.run.attempt"] = .int(value) }
        if let value = correlation.jobID { attributes["kinhin.job.id"] = .string(value) }
        if let value = correlation.workflow { attributes["cicd.pipeline.name"] = .string(value) }
        if let value = correlation.jobName { attributes["cicd.pipeline.task.name"] = .string(value) }
        if let value = correlation.repository { attributes["vcs.repository.name"] = .string(value) }
        let (root, wait) = state.withLock { state -> (any TelemetrySpan, Double?) in
            var wait: Double?
            if let queued = correlation.enqueuedAt, let started = correlation.startedAt, started >= queued {
                wait = started.timeIntervalSince(queued)
            }
            return (state.root, wait)
        }
        root.setAttributes(attributes)
        if let queued = correlation.enqueuedAt, let started = correlation.startedAt, started >= queued {
            root.startChild("queue_wait", start: queued, attributes: ["kinhin.source": "provider"])
                .end(at: started, error: nil)
        }
        return wait
    }

    private static func key(_ correlation: JobCorrelation) -> String {
        "\(correlation.runID ?? "-")/\(correlation.jobID ?? correlation.jobName ?? "-")"
    }

    /// A further job on the same instance (`runners_per_vm` above 1): its own child span under the root, so the root
    /// keeps the first job's identifiers instead of being overwritten.
    private func attachAdditional(_ correlation: JobCorrelation) -> Double? {
        guard let root = state.withLock({ $0.ended ? nil : $0.root }) else { return nil }
        var attributes: TelemetryAttributes = [:]
        if let value = correlation.runID { attributes["cicd.pipeline.run.id"] = .string(value) }
        if let value = correlation.runAttempt { attributes["kinhin.run.attempt"] = .int(value) }
        if let value = correlation.jobID { attributes["kinhin.job.id"] = .string(value) }
        if let value = correlation.workflow { attributes["cicd.pipeline.name"] = .string(value) }
        if let value = correlation.jobName { attributes["cicd.pipeline.task.name"] = .string(value) }
        let start = correlation.startedAt ?? correlation.enqueuedAt
        let job = root.startChild("job", start: start, attributes: attributes)
        var wait: Double?
        if let queued = correlation.enqueuedAt, let started = correlation.startedAt, started >= queued {
            wait = started.timeIntervalSince(queued)
            job.startChild("queue_wait", start: queued, attributes: ["kinhin.source": "provider"]).end(
                at: started, error: nil)
        }
        job.end(at: correlation.completedAt, error: nil)
        return wait
    }

    /// Adds provider-reported steps (with real start and finish times) under the run.
    func addProviderSteps(_ steps: [PipelineStep]) {
        let root = state.withLock { $0.ended ? nil : $0.root }
        guard let root else { return }
        for step in steps {
            guard let start = step.startedAt, let end = step.finishedAt, end >= start else { continue }
            root.startChild(
                "step", start: start,
                attributes: ["cicd.pipeline.task.name": .string(step.name), "kinhin.source": "provider"]
            ).end(at: end, error: step.state == .failed ? "step failed" : nil)
        }
    }

    /// Ends every open span and the root. Safe to call more than once.
    func finish(result: String, error: String? = nil) {
        let (root, open) = state.withLock { state -> ((any TelemetrySpan)?, [any TelemetrySpan]) in
            guard !state.ended else { return (nil, []) }
            state.ended = true
            defer { state.open = [:] }
            return (state.root, Array(state.open.values))
        }
        guard let root else { return }
        for span in open { span.end(error: error) }
        root.setAttributes(["kinhin.result": .string(result)])
        root.end(error: error)
    }

    /// True the first time it is called: a failure is counted once, whichever layer sees it first.
    func claimErrorCount() -> Bool {
        markers.withLock { markers in
            defer { markers.errorCounted = true }
            return !markers.errorCounted
        }
    }

    /// The runner took a job. True the first time (the caller counts the pickup then).
    /// `observed: false` is a job known only from its end (it started and finished between polls): the
    /// pickup still counts, but there is no run interval to time or trace.
    func markRunStarted(observed: Bool = true) -> Bool {
        let first = markers.withLock { markers -> Bool in
            guard !markers.pickupCounted else { return false }
            markers.pickupCounted = true
            if observed { markers.runStart = .now }
            return true
        }
        if first, observed { begin(.run) }
        return first
    }

    var hasRunStarted: Bool { markers.withLock { $0.runStart != nil } }

    /// The run ended: the measured duration in seconds (nil when it never started or already ended).
    func markRunFinished(at end: Date? = nil, error: String? = nil) -> Double? {
        let start: ContinuousClock.Instant? = markers.withLock { markers in
            guard let start = markers.runStart, !markers.runFinished else { return nil }
            markers.runFinished = true
            return start
        }
        guard let start else { return nil }
        self.end(.run, at: end, error: error)
        return (ContinuousClock.now - start) / .seconds(1)
    }

    var correlation: JobCorrelation? { state.withLock { $0.correlation } }
}
