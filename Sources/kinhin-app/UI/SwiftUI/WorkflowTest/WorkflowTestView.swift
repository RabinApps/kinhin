import Foundation
import KinhinKit
import SwiftUI

/// Sheet: pick a GitHub Actions workflow file, then run it locally (host
/// execution via `LocalWorkflowRunner`) before pushing to the forge.
struct WorkflowTestView: View {
    @State private var selectedJob: String?
    static let size = CGSize(width: 620, height: 560)

    let model: WorkflowTestModel
    let onClose: () -> Void

    var body: some View {
        SheetScaffold(
            title: "Test a workflow", width: Self.size.width,
            content: {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    chooser
                    if model.state == .idle {
                        preRun
                    } else if model.state == .running {
                        runningView
                    } else {
                        finishedView
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            footer: { footer }
        )
        .frame(height: Self.size.height, alignment: .topLeading)
        .task { if model.document == nil { await model.chooseWorkflow() } }
    }

    // MARK: - Chooser

    /// The choose button, the chosen file's path, and a spinner while it runs.
    private var chooser: some View {
        HStack(spacing: Spacing.md) {
            Button("Choose Workflow File…") { Task { await model.chooseWorkflow() } }
                .disabled(model.state == .running)
                .accessibilityIdentifier("workflow-choose-file")
            if let url = model.workflowURL {
                Text(verbatim: url.path)
                    .typeStyle(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if model.state == .running {
                ProgressView().controlSize(.small).accessibilityLabel("Working")
            }
        }
    }

    // MARK: - Pre-run

    @ViewBuilder
    private var preRun: some View {
        if let document = model.document {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Job").typeStyle(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                Picker("Job", selection: $selectedJob) {
                    Text("All jobs").tag(String?.none)
                    ForEach(document.jobs, id: \.id) { job in Text(verbatim: job.name).tag(Optional(job.id)) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Workflow job")
            }
            InsetRow(
                content: { RowLabel("Workflow") },
                trailing: { Text(verbatim: document.name).typeStyle(.caption).foregroundStyle(.secondary) })
            InsetRow(
                content: { RowLabel("Jobs") },
                trailing: {
                    Text("\(model.jobs.count) jobs").typeStyle(.caption).foregroundStyle(.secondary)
                })
        }
        if let error = model.error {
            StatusText(verbatim: error, style: .error).textSelection(.enabled)
        }
    }

    // MARK: - Running

    private var runningView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if model.jobs.isEmpty {
                HintText("No jobs to run")
            } else {
                ForEach(model.jobs, id: \.self) { job in
                    jobRow(job, state: model.jobState[job] ?? .pending)
                }
            }
            if let output = model.stepOutput {
                ScrollView {
                    Text(verbatim: output)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.sm + 2)
                }
                .frame(maxHeight: 140)
                .background(RoundedRectangle(cornerRadius: Radius.md).fill(Palette.grouped))
            }
        }
    }

    private func jobRow(_ job: String, state: PipelineStepState) -> some View {
        InsetRow(
            alignment: .firstTextBaseline,
            leading: { StateGlyph(state: state) },
            content: { Text(verbatim: job).typeStyle(.body).fontWeight(.medium) },
            trailing: {
                if let duration = model.jobDuration[job] {
                    Text(verbatim: AppFormat.duration(duration)).typeStyle(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                } else if state == .running {
                    Text("running").typeStyle(.caption).foregroundStyle(.secondary)
                } else if state == .pending {
                    Text("pending").typeStyle(.caption).foregroundStyle(.secondary)
                }
            })
    }

    /// A partial run says so (with how much was skipped) instead of reading as
    /// the generic "skipped".
    static func headline(for report: LocalRunReport?) -> String {
        guard let report else {
            return String(
                localized: "finished", bundle: .l10n, comment: "Workflow test headline when there is no report")
        }
        if report.outcome == .partial {
            return String(
                localized: "partial — \(report.unsupportedSkips.count) skipped as unsupported", bundle: .l10n,
                comment: "Workflow test headline; the number is how many steps were skipped")
        }
        return report.overallState.rawValue
    }

    // MARK: - Finished

    private var finishedView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                StateGlyph(state: model.report?.overallState ?? .pending)
                Text(verbatim: Self.headline(for: model.report)).typeStyle(.emphasis)
                Spacer()
                if let failed = model.report?.failedJobs, failed > 0 {
                    StatusText(
                        verbatim: String(
                            localized: "\(failed) failed", bundle: .l10n,
                            comment: "Workflow test: number of failed jobs"), style: .error)
                }
            }
            if let jobs = model.report?.jobs {
                ForEach(jobs, id: \.id) { step in
                    InsetRow(
                        leading: { StateGlyph(state: step.state) },
                        content: { Text(verbatim: step.name).typeStyle(.body).fontWeight(.medium).lineLimit(1) },
                        trailing: {
                            if let duration = step.duration {
                                Text(verbatim: AppFormat.duration(duration)).typeStyle(.caption).monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        })
                }
            }
            if let notices = model.report?.notices, !notices.isEmpty {
                HintText(verbatim: notices.joined(separator: "\n"))
            }
            if let error = model.error {
                StatusText(verbatim: error, style: .error).textSelection(.enabled)
            }
        }
    }

    // MARK: - Footer

    /// Run Workflow (or Run again) on the leading edge, Cancel while running, Done otherwise.
    private var footer: some View {
        HStack {
            if model.document != nil, model.state != .running {
                Button(model.state == .idle ? "Run Workflow" : "Run again") {
                    Task { await model.start(jobName: selectedJob) }
                }
                .controlSize(.small)
                .accessibilityIdentifier("workflow-run")
            }
            Spacer()
            if model.state == .running {
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("workflow-cancel")
            }
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
                .disabled(model.state == .running)
                .accessibilityIdentifier("sheet-done")
        }
    }
}

/// The colored state mark used by jobs and steps.
private struct StateGlyph: View {
    let state: PipelineStepState

    var body: some View {
        Text(verbatim: PipelineFormatter.symbol(for: state))
            .typeStyle(.emphasis)
            .foregroundStyle(color)
            .frame(width: 16)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .succeeded: return StatusStyle.ok.color
        case .failed: return StatusStyle.error.color
        case .running: return StatusStyle.warn.color
        case .pending, .skipped, .cancelled: return StatusStyle.secondary.color
        }
    }
}
