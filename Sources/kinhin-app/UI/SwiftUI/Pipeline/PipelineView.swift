import KinhinKit
import SwiftUI

/// The pipeline sheet: a VM's live pipeline as a list of jobs; clicking a job
/// shows just that job's steps. Refreshes every two seconds while up.
struct PipelineView: View {
    static let size = CGSize(width: 560, height: 520)

    let model: PipelineModel
    let onClose: () -> Void

    var body: some View {
        SheetScaffold(
            verbatimTitle: titleText, width: Self.size.width,
            content: {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    header
                    if let message = model.emptyMessage {
                        StatusText(verbatim: message, style: model.error == nil ? .secondary : .error)
                        Spacer(minLength: 0)
                    } else if model.logTarget != nil {
                        outputPane
                    } else if let job = model.selectedJob {
                        jobDetail(job)
                    } else {
                        jobList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            footer: { footer }
        )
        .frame(height: Self.size.height)
        .task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                await model.refresh()
            }
        }
    }

    // MARK: - Header and footer

    /// The sheet title: the forge's mark was part of the old heading; the scaffold's title stays plain text.
    private var titleText: String { model.title }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                if let detail = model.detail { ForgeIconView(forge: detail.forge, size: 14) }
                Chip(verbatim: model.vmID, tone: .neutral)
                if let subtitle = model.subtitle { HintText(verbatim: subtitle) }
            }
            if let notice = model.notice { HintText(verbatim: notice) }
            if model.detail != nil, let error = model.error { StatusText(verbatim: error, style: .error) }
        }
    }

    private var footer: some View {
        SheetCloseFooter(close: onClose) {
            if model.selectedJob != nil {
                Button {
                    model.back()
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "chevron.backward")
                        model.logTarget != nil ? Text("Steps") : Text("All jobs")
                    }
                }
                .accessibilityLabel(
                    model.logTarget != nil ? Text("Back to the job's steps") : Text("Back to all jobs"))
            }
            if let url = (model.selectedJob?.url ?? model.detail?.url).flatMap(URL.init(string:)) {
                Link("Open in browser", destination: url)
                    .typeStyle(.caption)
            }
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
                Text(job.name).typeStyle(.emphasis).lineLimit(2)
                // Ticks every second between polls, so elapsed time and "ago" stay live.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(
                        verbatim: [
                            PipelineModel.label(for: job.state), model.timing(of: job, now: context.date),
                            job.isCurrent
                                ? String(
                                    localized: "this VM", bundle: .l10n,
                                    comment: "Pipeline job row tag: this job runs on the VM being inspected") : nil,
                        ].compactMap { $0 }.joined(separator: " · ")
                    )
                    .typeStyle(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward").foregroundStyle(.tertiary).accessibilityHidden(true)
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
                Text(job.name).typeStyle(.emphasis).lineLimit(2)
            }
            if let hint = model.stepsHint(for: job) {
                HintText(verbatim: hint)
            }
            ScrollView {
                VStack(spacing: 6) {
                    Button {
                        model.selectJobOutput()
                    } label: {
                        outputRow(
                            String(localized: "Whole job output", bundle: .l10n, comment: "Pipeline job output row"))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show the output of \(job.name)")
                    ForEach(Array(job.steps.enumerated()), id: \.offset) { index, step in
                        Button {
                            model.selectStep(index)
                        } label: {
                            stepRow(step)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show the output of \(step.name), \(PipelineModel.label(for: step.state))")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func outputRow(_ title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet").accessibilityHidden(true).foregroundStyle(.secondary).frame(width: 16)
            Text(verbatim: title).typeStyle(.caption)
            Spacer(minLength: 8)
            Image(systemName: "chevron.forward").foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .formSurface(cornerRadius: 6)
        .contentShape(Rectangle())
    }

    private func stepRow(_ step: PipelineStep) -> some View {
        HStack(spacing: 10) {
            StateGlyph(state: step.state)
            Text(step.name).typeStyle(.caption).lineLimit(2)
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let timing = model.timing(of: step, now: context.date) {
                    Text(timing).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.forward").foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .formSurface(cornerRadius: 6)
        .contentShape(Rectangle())
    }

    // MARK: - Output

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let state = model.logState { StateGlyph(state: state) }
                Text(model.logTitle).typeStyle(.emphasis).lineLimit(2)
                Spacer(minLength: 8)
                if model.logState == .running {
                    Chip("live", tone: .ok, symbol: "circle.fill")
                }
            }
            if let step = model.openStep {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let timing = model.timing(of: step, now: context.date) { HintText(verbatim: timing) }
                }
            }
            if let notice = model.logNotice { HintText(verbatim: notice) }
            if let placeholder = model.logPlaceholder {
                StatusText(verbatim: placeholder, style: model.logError == nil ? .secondary : .error)
                Spacer(minLength: 0)
            } else if let text = model.log?.text {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(text)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .formSurface(cornerRadius: 6)
                    // Follow the tail as new output arrives.
                    .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
    }
}

/// The colored state mark used by jobs and steps.
private struct StateGlyph: View {
    let state: PipelineStepState

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .frame(width: 16)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch state {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .pending: return "circle"
        case .skipped: return "minus.circle"
        case .cancelled: return "slash.circle"
        }
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
