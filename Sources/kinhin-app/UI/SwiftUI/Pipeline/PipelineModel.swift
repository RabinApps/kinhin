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

    // MARK: - Selection

    var selectedJob: PipelineJob? {
        guard let selectedJobID else { return nil }
        return detail?.jobs.first { $0.id == selectedJobID }
    }

    func select(_ job: PipelineJob) { selectedJobID = job.id }

    func back() { selectedJobID = nil }

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

    func duration(of step: PipelineStep) -> String? {
        Self.duration(from: step.startedAt, to: step.state.isFinished ? step.finishedAt : nil)
    }

    func duration(of job: PipelineJob) -> String? {
        Self.duration(from: job.startedAt, to: job.state.isFinished ? job.finishedAt : nil)
    }
}
