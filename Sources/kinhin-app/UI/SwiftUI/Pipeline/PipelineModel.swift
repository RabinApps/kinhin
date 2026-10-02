import Foundation
import KinhinKit
import Observation

/// State behind the pipeline sheet: the live pipeline one VM is running, as a
/// list of jobs, and the single job the user drilled into to see its steps.
@MainActor
@Observable
final class PipelineModel {
    let vmID: String
    @ObservationIgnored let controller: FleetController

    /// The last pipeline the forge reported. Kept after the job ends so the
    /// final state stays readable (`ended`).
    private(set) var detail: PipelineDetail?
    /// The forge or backend failure from the latest refresh, if any.
    private(set) var error: String?
    /// The first refresh has answered (distinguishes "loading" from "no job").
    private(set) var loaded = false
    /// The latest refresh found no running job after one had been seen.
    private(set) var ended = false
    /// The job whose steps are shown; nil shows the job list.
    private(set) var selectedJobID: String?

    /// What the output pane follows within the selected job.
    enum LogTarget: Equatable {
        /// The whole job's output.
        case job
        /// One step's output, by position in the job's steps.
        case step(Int)
    }

    /// The output being shown; nil shows the job's steps.
    private(set) var logTarget: LogTarget?
    /// The latest output for `logTarget` (kept across refreshes, so the text
    /// doesn't blank between polls).
    private(set) var log: PipelineLog?
    private(set) var logError: String?
    /// The first output read for this target has answered.
    private(set) var logLoaded = false

    init(vmID: String, controller: FleetController) {
        self.vmID = vmID
        self.controller = controller
    }

    // MARK: - Loading

    func load() async {
        do {
            let latest = try await controller.fetchPipelineDetail(vmID: vmID)
            if let latest {
                detail = latest
                ended = false
            } else if detail != nil {
                ended = true
            }
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    /// One refresh of everything on screen: the pipeline, then the output when
    /// a step or job's output is open.
    func refresh() async {
        await load()
        await loadLog()
    }

    func loadLog() async {
        guard let target = logTarget, let job = selectedJob else { return }
        let index: Int?
        switch target {
        case .job: index = nil
        case .step(let step): index = step
        }
        do {
            let latest = try await controller.fetchPipelineLog(vmID: vmID, jobID: job.id, stepIndex: index)
            // The user may have moved on while the read was in flight.
            guard logTarget == target, selectedJobID == job.id else { return }
            if let latest { log = latest }
            logError = nil
        } catch is CancellationError {
            return
        } catch {
            guard logTarget == target else { return }
            logError = error.localizedDescription
        }
        logLoaded = true
    }

    // MARK: - Selection

    var selectedJob: PipelineJob? {
        guard let selectedJobID else { return nil }
        return detail?.jobs.first { $0.id == selectedJobID }
    }

    func select(_ job: PipelineJob) {
        selectedJobID = job.id
        closeLog()
    }

    func selectStep(_ index: Int) { openLog(.step(index)) }

    func selectJobOutput() { openLog(.job) }

    private func openLog(_ target: LogTarget) {
        logTarget = target
        log = nil
        logError = nil
        logLoaded = false
    }

    private func closeLog() {
        logTarget = nil
        log = nil
        logError = nil
        logLoaded = false
    }

    /// One level up: from the output to the job's steps, from those to the jobs.
    func back() {
        if logTarget != nil {
            closeLog()
        } else {
            selectedJobID = nil
        }
    }

    // MARK: - Output pane

    /// The step whose output is open (nil for the whole job, or no output open).
    var openStep: PipelineStep? {
        guard case .step(let index) = logTarget, let steps = selectedJob?.steps, steps.indices.contains(index) else {
            return nil
        }
        return steps[index]
    }

    var logTitle: String {
        switch logTarget {
        case .step: return openStep?.name ?? "Step"
        case .job: return selectedJob.map { "\($0.name) — whole job" } ?? "Job"
        case nil: return ""
        }
    }

    /// The state of what the output follows, so the pane can say it is live.
    var logState: PipelineStepState? {
        switch logTarget {
        case .step: return openStep?.state
        case .job: return selectedJob?.state
        case nil: return nil
        }
    }

    /// What to show in place of output text.
    var logPlaceholder: String? {
        if let log, !log.text.isEmpty { return nil }
        if let logError { return logError }
        guard logLoaded else { return "Loading output…" }
        if logState == .pending { return "Not started yet." }
        if log == nil {
            return
                "\(detail?.forge.displayName ?? "The forge") has no output for this \(logTarget == .job ? "job" : "step") (yet)."
        }
        return "No output yet."
    }

    var logNotice: String? {
        log?.truncated == true ? "Showing only the most recent output." : nil
    }

    // MARK: - Text

    var title: String {
        guard let detail else { return "Pipeline" }
        return "\(detail.forge.displayName) · \(detail.title)"
    }

    /// Repository, ref and short commit on one line.
    var subtitle: String? {
        guard let detail else { return nil }
        let parts = [detail.repository, detail.ref, detail.sha.map { String($0.prefix(7)) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What to show when there is no pipeline to list.
    var emptyMessage: String? {
        if detail != nil { return nil }
        if let error { return error }
        return loaded ? "No job is running on this VM." : "Loading…"
    }

    /// A note about what the forge can show, or that the job has ended.
    var notice: String? {
        if ended { return "This job has finished; showing its last known state." }
        if detail?.granularity == .job {
            let name = detail?.forge.displayName ?? "This forge"
            return "\(name) reports jobs, not individual steps."
        }
        return nil
    }

    func stepsHint(for job: PipelineJob) -> String? {
        PipelineFormatter.stepsHint(for: job, forge: detail?.forge ?? .github)
    }

    static func label(for state: PipelineStepState) -> String { PipelineFormatter.label(for: state) }

    static func symbol(for state: PipelineStepState) -> String { PipelineFormatter.symbol(for: state) }

    static func duration(from start: Date?, to end: Date?, now: Date = Date()) -> String? {
        PipelineFormatter.duration(from: start, to: end, now: now)
    }

    /// Live timing ("1m 06s · started 1m ago"); the view passes its ticking clock.
    func timing(of step: PipelineStep, now: Date = Date()) -> String? {
        PipelineFormatter.timing(state: step.state, startedAt: step.startedAt, finishedAt: step.finishedAt, now: now)
    }

    func timing(of job: PipelineJob, now: Date = Date()) -> String? {
        PipelineFormatter.timing(state: job.state, startedAt: job.startedAt, finishedAt: job.finishedAt, now: now)
    }
}
