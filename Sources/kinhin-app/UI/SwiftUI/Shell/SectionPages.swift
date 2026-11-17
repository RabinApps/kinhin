import KinhinKit
import SwiftUI

// The pages of the sections that are still thin adapters over the per-domain views. A later pass redesigns each from
// `design/kinhin-app.fig`; until then these only host what exists.

/// A page heading (display type) over its content, which fills the rest of the page.
struct PageHeaderStack<Content: View, Trailing: View>: View {
    let title: String
    let trailing: Trailing
    let content: Content

    init(title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .center) {
                Text(verbatim: title)
                    .typeStyle(.display)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Spacing.md)
                trailing
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension PageHeaderStack where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

// MARK: - Diagnostics

/// Diagnostics: a segmented control over Health, Logs, Benchmarks, Containers and Tools. Each pane is the existing
/// view, inline instead of in a sheet.
struct DiagnosticsPage: View {
    let model: MainTabsModel

    var body: some View {
        PageHeaderStack(title: MainSection.diagnostics.label) {
            Picker(
                "Diagnostics sections",
                selection: Binding(get: { model.diagnosticsPane }, set: { model.selectDiagnosticsPane($0) })
            ) {
                ForEach(DiagnosticsPane.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Diagnostics sections")
        } content: {
            pane
        }
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

/// The Logs pane: the searchable log over an Open-folder button. The ring buffer is re-read every second while the
/// pane is up.
struct LogsPane: View {
    let model: LogsModel
    let openFolder: () -> Void

    var body: some View {
        VStack(spacing: Spacing.sm) {
            LogsView(model: model)
            HStack {
                Button("Open logs folder", action: openFolder)
                Spacer()
            }
        }
        .task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                model.refresh()
            }
        }
    }
}

/// The Tools pane: the entry points to the Test Workflow and Make a Video sheets.
struct ToolsPane: View {
    let testWorkflow: () -> Void
    let makeVideo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Card(
                title: "Test a workflow", subtitle: "Run a workflow file locally before pushing", layout: .fill
            ) {
                Button("Test Workflow…", action: testWorkflow)
                    .accessibilityIdentifier("open-workflow-test")
            }
            Card(title: "Make a video", subtitle: "Launch videos built in a container", layout: .fill) {
                HStack(spacing: Spacing.md) {
                    Button("Make a Video…", action: makeVideo)
                        .accessibilityIdentifier("open-videos")
                    HintText("Builds download the video image on first run.")
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview("Tools pane") {
    ToolsPane(testWorkflow: {}, makeVideo: {})
        .padding(Spacing.lg)
        .frame(width: 560, height: 300)
}
