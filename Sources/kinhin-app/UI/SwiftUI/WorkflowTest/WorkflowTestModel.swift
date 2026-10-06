import AppKit
import Foundation
import KinhinKit
import Observation
import SwiftUI

/// State behind the "Test Workflow…" sheet: a parsed workflow, its jobs, a
/// live run of the shared `LocalWorkflowRunner`, and the states/outputs of
/// every step as they finish.
@MainActor
@Observable
final class WorkflowTestModel {
    /// Open a workflow file in Finder. Tests inject a stub; the app uses
    /// `NSOpenPanel` restricted to YAML files.
    var chooseFile: () async throws -> URL? = { @MainActor in
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.yaml]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// The parsed document, if a file was chosen and parsed.
    var document: WorkflowDocument?

    /// The jobs the document declares. Empty while parsing, after a parse
    /// error, or when no file has been chosen yet.
    var jobs: [String] { document?.jobs.map(\.id) ?? [] }

    var state: WorkflowRunState = .idle

    enum WorkflowRunState: Equatable {
        case idle, running, succeeded, failed, cancelled
    }

    /// The parsed workflow's name (its `name:` key).
    var workflowName: String? { document?.name }

    /// The working directory the run uses: the repo root (found by walking
    /// up until a `.git` directory exists), or the folder a file lives in.
    var workingDirectory: URL?

    /// The final report once the run finishes (succeeded, failed or cancelled).
    var report: LocalRunReport?

    /// Errors from parsing or running. Non-nil → the sheet shows an alert.
    var error: String?

    /// Files each step printed so far (kept across refreshes so output does
    /// not blank between polls).
    private(set) var stepOutputs: [String: String] = [:]
    private(set) var stepErrors: [String: String] = [:]
    private(set) var stepNotices: [String: [String]] = [:]

    // MARK: - Init

    init(chooseFile: @escaping () async throws -> URL? = { @MainActor in nil }, shell: ShellRunning = Shell()) {
        self.chooseFile = chooseFile
        self.shell = shell
    }

    @ObservationIgnored private let shell: ShellRunning
    @ObservationIgnored private var runTask: Task<Void, Never>?

    func chooseWorkflow() async {
        do {
            guard let url = try await chooseFile() else { return }
            let data = try Data(contentsOf: url)
            let parsed = try parseWorkflow(data, at: url)
            document = parsed
            workflowURL = url
            workingDirectory = repositoryRoot(from: url.deletingLastPathComponent())
            error = nil
            report = nil
            state = .idle
        } catch {
            self.error = error.localizedDescription
            document = nil
            state = .idle
        }
    }

    private(set) var workflowURL: URL?

    // MARK: - Start

    /// Parses the chosen file, then runs every job (or the single `--job` one)
    /// in `needs`-topological order through `LocalWorkflowRunner`.
    func start(jobName: String? = nil) async {
        if document == nil {
            await chooseWorkflow()
            guard document != nil else { return }
        }
        guard let document, let workingDirectory else { return }
        report = nil
        error = nil
        stepOutputs = [:]
        stepNotices = [:]
        state = .running
        let runner = LocalWorkflowRunner(shell: shell) { [weak self] event in
            Task { @MainActor in self?.onEvent(event) }
        }
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await runner.run(
                    document: document, jobs: selectedJobName(jobName), workingDirectory: workingDirectory)
                report = result
                state =
                    result.overallState == .succeeded
                    ? .succeeded : (result.overallState == .failed ? .failed : .cancelled)
            } catch is CancellationError {
                state = .cancelled
            } catch {
                self.error = error.localizedDescription
                state = .failed
            }
            runTask = nil
        }
        await runTask?.value
    }

    private func onEvent(_ event: LocalRunEvent) {
        switch event {
        case .jobStarted, .jobFinished, .stepStarted, .stepFinished, .needSkipped, .matrixSkipped:
            break
        case .stepOutput(let step, let output):
            stepOutputs[step] = output
        case .stepSkipped(let step, notice: let notice):
            var current = stepNotices[step] ?? []
            current.append(notice)
            stepNotices[step] = current
        case .stepNotice(let step, notice: let notice):
            var current = stepNotices[step] ?? []
            current.append(notice)
            stepNotices[step] = current
        }
    }

    private func selectedJobName(_ requested: String?) -> [String] {
        guard let requested, !requested.isEmpty else { return [] }
        return [requested]
    }

    // MARK: - Cancel

    func cancel() {
        // `LocalWorkflowRunner` is an actor: cancelling the `run` task is the
        // only cooperative path. The shell honours task cancellation itself.
        runTask?.cancel()
    }

    private func repositoryRoot(from folder: URL) -> URL {
        var current = folder
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) { return current }
            current.deleteLastPathComponent()
        }
        return folder
    }

    // MARK: - Output

    var stepOutput: String? {
        stepOutputs.first?.value
    }

    var stepError: String? {
        stepErrors.first?.value
    }

    var stepNotice: [String]? {
        stepNotices.first?.value
    }

    // MARK: - Job state / duration

    /// The final state of a job once the run has finished, or `.pending` when
    /// nothing has run yet.
    var jobState: [String: PipelineStepState] {
        guard let report else { return [:] }
        var map: [String: PipelineStepState] = [:]
        for job in report.jobs {
            map[job.name] = job.state
        }
        return map
    }

    /// The elapsed time of a finished job, or nil when it is still running.
    var jobDuration: [String: TimeInterval] {
        guard let report else { return [:] }
        var map: [String: TimeInterval] = [:]
        for job in report.jobs {
            map[job.name] = job.duration
        }
        return map
    }
}
