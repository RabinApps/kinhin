import SwiftUI

/// Diagnostics: the page title with its one-line subtitle and a segmented control over Health, Logs, Benchmarks,
/// Containers and Tools. Each pane is inline, never a sheet.
struct DiagnosticsPage: View {
    let model: MainTabsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            // The title and subtitle get the whole row; the pane tabs sit on their own row below them. Beside the
            // title the tabs' ideal width left the title a sliver of the page, so it broke into "Diag-nos-tics".
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(verbatim: MainSection.diagnostics.label)
                    .typeStyle(.display)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                HintText("Health, logs, benchmarks and tools in one place.")
            }
            Picker(
                "Diagnostics sections",
                selection: Binding(get: { model.diagnosticsPane }, set: { model.selectDiagnosticsPane($0) })
            ) {
                ForEach(DiagnosticsPane.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Diagnostics sections")
            pane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var pane: some View {
        let models = model.models
        switch model.diagnosticsPane {
        case .health:
            DiagnosticsView(model: models.ensureDiagnosticsModel())
        case .logs:
            LogsPane(model: models.ensureLogsModel(), openFolder: { models.delegate?.openLogsFolder() })
        case .benchmarks:
            if let benchmarks = models.benchmarksModel { BenchmarksView(model: benchmarks) }
        case .containers:
            if let containers = models.containersModel { ContainersView(model: containers) }
        case .tools:
            ToolsPane(
                testWorkflow: { model.present(.workflowTest) },
                makeVideo: { model.present(.videos) })
        }
    }
}
