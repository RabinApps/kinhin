import KinhinKit
import SwiftUI

/// Advanced → Benchmarks: what to measure, a Run button, live progress, the
/// cross-runtime boot comparison, each suite's steps, the toolchains table and
/// the history of earlier runs. State and actions live in `BenchmarksModel`.
struct BenchmarksView: View {
    let model: BenchmarksModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                setupCard
                if model.isRunning { progressCard }
                if let comparison = model.bootComparison { bootCard(comparison) }
                ForEach(Array(model.stepSuites.enumerated()), id: \.offset) { _, suite in stepsCard(suite) }
                ForEach(Array(model.toolchainSuites.enumerated()), id: \.offset) { _, suite in toolchainsCard(suite) }
                if !model.history.isEmpty { historyCard }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear { model.stopPolling() }
    }

    // MARK: - Setup

    private var setupCard: some View {
        FormCard(
            title: "Benchmarks",
            subtitle:
                "Measure how fast runtimes boot, workloads run and toolchains install on this Mac. Temporary VMs and containers are removed afterwards."
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(BenchmarkOptions.Suite.allCases, id: \.self) { suite in
                    Toggle(
                        isOn: Binding(
                            get: { model.selectedSuites.contains(suite) },
                            set: { on in
                                if on { model.selectedSuites.insert(suite) } else { model.selectedSuites.remove(suite) }
                            })
                    ) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: suite.label)
                            HintText(verbatim: suite.summary)
                        }
                    }
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("benchmarks-suite-\(suite.rawValue)")
                }
            }
            HStack {
                Picker("Intensity", selection: Binding(get: { model.intensity }, set: { model.intensity = $0 })) {
                    ForEach([BenchmarkOptions.Intensity.quick, .thorough], id: \.self) {
                        Text(verbatim: $0.label).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(model.isRunning)
                .accessibilityLabel("Benchmark intensity")
                Spacer()
                if model.isRunning {
                    Button("Cancel") { model.cancelClicked() }
                        .accessibilityIdentifier("benchmarks-cancel")
                } else {
                    Button("Run…") { model.runClicked() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canRun)
                        .accessibilityIdentifier("benchmarks-run")
                }
            }
            if let warning = model.toolchainsWarning { StatusText(verbatim: warning, style: .warn) }
            if !model.status.text.isEmpty { StatusText(verbatim: model.status.text, style: model.status.style) }
        }
    }

    private var progressCard: some View {
        FormCard(title: "Running") {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).accessibilityLabel("Working")
                Text(verbatim: model.progressLine ?? "…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(verbatim: AppFormat.duration(model.elapsed))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Results

    private func bootCard(_ comparison: BootComparison) -> some View {
        FormCard(
            title: Text(verbatim: BenchmarkOptions.Suite.boot.label),
            subtitle: Text("Median per phase, one row per runtime.")
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        Text(verbatim: "").gridColumnAlignment(.leading)
                        ForEach(comparison.columns, id: \.self) { column in
                            Text(verbatim: column).font(.system(size: 10, weight: .semibold)).foregroundStyle(
                                .secondary)
                        }
                    }
                    ForEach(comparison.rows) { row in
                        GridRow {
                            Text(verbatim: row.runtime).font(.system(size: 11, weight: .medium))
                            ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                                Text(verbatim: cell).font(.system(size: 11, design: .monospaced))
                            }
                        }
                    }
                }
            }
            ForEach(comparison.rows.filter { $0.note != nil }) { row in
                HintText(verbatim: "\(row.runtime): \(row.note ?? "")")
            }
        }
    }

    private func stepsCard(_ suite: BenchmarkSuiteResult) -> some View {
        FormCard(title: Text(verbatim: model.title(of: suite))) {
            if let problem = model.problem(of: suite) { StatusText(verbatim: problem.text, style: problem.style) }
            ForEach(model.lines(of: suite)) { line in
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: line.name).font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(verbatim: line.value)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.skipped ? Color.secondary : Color.primary)
                        if let detail = line.detail { HintText(verbatim: detail) }
                    }
                }
            }
        }
    }

    private func toolchainsCard(_ suite: BenchmarkSuiteResult) -> some View {
        FormCard(title: Text(verbatim: model.title(of: suite))) {
            HStack(spacing: 0) {
                ForEach(BenchmarksModel.ToolchainSort.allCases, id: \.self) { column in
                    Button {
                        model.sortToolchains(by: column)
                    } label: {
                        HStack(spacing: 2) {
                            Text(verbatim: column.label)
                            if model.toolchainSort == column {
                                Image(systemName: model.toolchainSortAscending ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 8))
                                    .accessibilityHidden(true)
                            }
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: column == .tool ? 130 : 80, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(
                            localized: "Sort by \(column.label)", bundle: .l10n,
                            comment: "VoiceOver label of a toolchains table column header; %@ is the column name"))
                }
            }
            ForEach(model.toolchainRows(of: suite)) { row in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Text(verbatim: row.tool)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(row.failed ? StatusStyle.error.color : Color.primary)
                            .frame(width: 130, alignment: .leading)
                        ForEach([row.install, row.verify, row.workload], id: \.self) { value in
                            Text(verbatim: value)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 80, alignment: .leading)
                        }
                    }
                    if let note = row.note {
                        HintText(verbatim: note).padding(.leading, 130)
                    }
                }
            }
        }
    }

    private var historyCard: some View {
        FormCard(title: "History", subtitle: "The newest reports are kept; click one to see it.") {
            ForEach(Array(model.history.prefix(10)), id: \.url) { entry in
                Button {
                    model.show(entry)
                } label: {
                    HStack {
                        Text(verbatim: model.historyTitle(entry)).font(.system(size: 11))
                        Spacer()
                        Text(verbatim: AppFormat.relative(entry.startedAt)).font(.system(size: 11)).foregroundStyle(
                            .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    String(
                        localized: "Show the benchmark from \(model.historyTitle(entry))", bundle: .l10n,
                        comment: "VoiceOver label of a benchmark history row; %@ is the run's date"))
            }
        }
    }
}
