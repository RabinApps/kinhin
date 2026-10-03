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
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.state == .idle {
                preRun
            } else if model.state == .running {
                runningView
            } else {
                finishedView
            }
            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .task { if model.document == nil { await model.chooseWorkflow() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            if let name = model.workflowName {
                Text(name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            } else {
                Text("Test Workflow").font(.system(size: 16, weight: .semibold)).lineLimit(1)
            }
            Spacer()
            if model.state == .running {
                ProgressView().controlSize(.small)
            }
        }
        .foregroundStyle(model.state == .running ? Color.accentColor : Color.primary)
    }

    // MARK: - Pre-run

    private var preRun: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a workflow file")
                .font(.system(size: 13, weight: .semibold))
            Button {
                Task { await model.chooseWorkflow() }
            } label: {
                HStack {
                    Image(systemName: "folder")
                    Text("Choose Workflow File…")
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            if let document = model.document {
                Text(model.workflowURL?.path ?? "")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                Picker("Job", selection: $selectedJob) {
                    Text("All jobs").tag(String?.none)
                    ForEach(document.jobs, id: \.id) { job in Text(job.name).tag(Optional(job.id)) }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Workflow job")
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Workflow").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        Spacer()
                        Text(document.name).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                    }
                    HStack {
                        Text("Jobs").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(model.jobs.count) job(s)").font(.system(size: 12))
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(8)
                Button("Run Workflow") {
                    Task { await model.start(jobName: selectedJob) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.state == .running)
            }
            if let error = model.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red)
            }
        }
    }

    // MARK: - Running

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.jobs.isEmpty {
                Text("No jobs to run")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.jobs, id: \.self) { job in
                    jobRow(job, state: model.jobState[job] ?? .pending)
                }
            }
            if let output = model.stepOutput {
                ScrollView {
                    Text(output)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 140)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)
            }
            Button {
                model.cancel()
            } label: {
                HStack {
                    Image(systemName: "stop.circle")
                    Text("Cancel")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.15))
                .foregroundStyle(Color.red)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
    }

    private func jobRow(_ job: String, state: PipelineStepState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StateGlyph(state: state)
            Text(job)
                .font(.system(size: 12, design: .monospaced))
            Spacer()
            if let duration = model.jobDuration[job] {
                Text(duration < 60 ? "\(Int(duration))s" : "\(Int(duration / 60))m \(Int(duration) % 60)s")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(6)
    }

    // MARK: - Finished

    private var finishedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StateGlyph(state: model.report?.overallState ?? .pending)
                Text(model.report?.overallState.rawValue ?? "finished")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let failed = model.report?.failedJobs, failed > 0 {
                    Text("\(failed) failed")
                        .font(.system(size: 11)).foregroundStyle(.red)
                }
            }
            if let jobs = model.report?.jobs {
                ForEach(jobs, id: \.id) { step in
                    HStack {
                        StateGlyph(state: step.state)
                        Text(step.name)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        if let duration = step.duration {
                            Text(duration < 60 ? "\(Int(duration))s" : "\(Int(duration / 60))m \(Int(duration) % 60)s")
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                }
            }
            if let notices = model.report?.notices, !notices.isEmpty {
                Text(notices.joined(separator: "\n"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await model.start(jobName: selectedJob) }
            } label: {
                Text("Run again")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            if model.state == .running {
                Button {
                    model.cancel()
                } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.escape)
            } else {
                Button {
                    onClose()
                } label: {
                    Text("Done")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.top, 8)
    }
}

/// The colored state mark used by jobs and steps.
private struct StateGlyph: View {
    let state: PipelineStepState

    var body: some View {
        Text(PipelineFormatter.symbol(for: state))
            .font(.system(size: 14, weight: .bold))
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

