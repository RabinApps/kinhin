import KinhinKit
import SwiftUI

/// The pipeline sheet: a VM's live pipeline as a list of jobs; clicking a job
/// shows just that job's steps. Refreshes every two seconds while up.
struct PipelineView: View {
    static let size = CGSize(width: 560, height: 520)

    let model: PipelineModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let message = model.emptyMessage {
                StatusText(text: message, style: model.error == nil ? .secondary : .error)
                Spacer(minLength: 0)
            } else if let job = model.selectedJob {
                jobDetail(job)
            } else {
                jobList
            }
            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                await model.load()
            }
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let detail = model.detail { ForgeIconView(forge: detail.forge, size: 16) }
                Text(model.title).font(.system(size: 18, weight: .bold)).lineLimit(1)
            }
            Text(model.vmID).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            if let subtitle = model.subtitle { HintText(subtitle) }
            if let notice = model.notice { HintText(notice) }
            if model.detail != nil, let error = model.error { StatusText(text: error, style: .error) }
        }
    }

    private var footer: some View {
        HStack {
            if model.selectedJob != nil {
                Button("‹ All jobs") { model.back() }
                    .accessibilityLabel("Back to all jobs")
            }
            if let url = (model.selectedJob?.url ?? model.detail?.url).flatMap(URL.init(string:)) {
                Link("Open in browser", destination: url)
                    .font(.system(size: 12))
            }
            Spacer()
            Button("Close", action: onClose)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Close pipeline")
        }
    }

    // MARK: - Job list

    private var jobList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(model.detail?.jobs ?? []) { job in
                    Button {
                        model.select(job)
                    } label: {
                        jobRow(job)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show steps of \(job.name), \(PipelineModel.label(for: job.state))")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func jobRow(_ job: PipelineJob) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StateGlyph(state: job.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(
                    [
                        PipelineModel.label(for: job.state), model.duration(of: job),
                        job.isCurrent ? "this VM" : nil,
                    ].compactMap { $0 }.joined(separator: " · ")
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("›").foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .formSurface(cornerRadius: 8)
        .contentShape(Rectangle())
    }

    // MARK: - One job's steps

    private func jobDetail(_ job: PipelineJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StateGlyph(state: job.state)
                Text(job.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
            }
            if let hint = model.stepsHint(for: job) {
                HintText(hint)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(job.steps.enumerated()), id: \.offset) { _, step in
                        stepRow(step)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func stepRow(_ step: PipelineStep) -> some View {
        HStack(spacing: 10) {
            StateGlyph(state: step.state)
            Text(step.name).font(.system(size: 12)).lineLimit(2)
            Spacer(minLength: 8)
            if let duration = model.duration(of: step) {
                Text(duration).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .formSurface(cornerRadius: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.name), \(PipelineModel.label(for: step.state))")
    }
}

/// The colored state mark used by jobs and steps.
private struct StateGlyph: View {
    let state: PipelineStepState

    var body: some View {
        Text(PipelineModel.symbol(for: state))
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
