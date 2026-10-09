import KinhinKit
import SwiftUI

/// The main window's content: a segmented tab bar over the Fleet, Setup and
/// Advanced pages, with the Logs and Diagnostics sheets. Navigation state
/// lives in `MainTabsModel`; each page is the existing per-domain view.
struct MainTabsView: View {
    @Bindable var model: MainTabsModel

    var body: some View {
        VStack(spacing: 14) {
            // No tab bar while first-run setup gates the window.
            if !model.isGatedBySetup {
                Picker(
                    "kinhin sections",
                    selection: Binding(get: { model.selectedTab }, set: { model.userSelected($0) })
                ) {
                    ForEach(model.visibleTabs, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                .accessibilityLabel("kinhin sections")
                .frame(width: 300)
                .padding(.top, 16)
            }

            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // The sponsor star sits in the window's top-right corner, over every
        // tab (the traffic lights own the top-left). Hidden while first-run
        // setup gates the window, matching the sheets.
        .overlay(alignment: .topTrailing) {
            if !model.isGatedBySetup {
                Button {
                    model.present(.sponsor)
                } label: {
                    Image(systemName: "star.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.yellow)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Sponsor kinhin")
                .accessibilityLabel("Sponsor kinhin")
                .accessibilityIdentifier("sponsor-button")
                .padding(.trailing, 14)
                .padding(.top, 10)
            }
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .logs:
                LogsSheet(
                    model: model.models.ensureLogsModel(),
                    openFolder: { model.models.delegate?.openLogsFolder() },
                    close: { model.dismissSheet() })
            case .diagnostics:
                DiagnosticsView(model: model.models.ensureDiagnosticsModel(), onClose: { model.dismissSheet() })
            case .pipeline(let vmID):
                if let pipeline = model.models.pipelineModel, pipeline.vmID == vmID {
                    PipelineView(model: pipeline, onClose: { model.dismissSheet() })
                }
            case .workflowTest:
                if let model = model.models.workflowTestModel {
                    WorkflowTestView(model: model, onClose: { self.model.dismissSheet() })
                }
            case .sponsor:
                SponsorSheet(close: { model.dismissSheet() })
            }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch model.selectedTab {
        case .fleet:
            FleetView(model: model.models.fleetModel)
        case .setup:
            if let wizard = model.models.wizardModel { WizardView(model: wizard) }
        case .advanced:
            AdvancedView(model: model)
        }
    }
}

/// Widths that make up the Advanced page. The window's minimum width is derived
/// from them so the form cards are never clipped, even with the sidebar open.
enum AdvancedLayout {
    static let sidebarExpanded: CGFloat = 176
    static let sidebarCollapsed: CGFloat = 52
    static let detailPadding: CGFloat = 16
    /// The form column: a card plus the sections' own leading inset and slack.
    static let contentWidth: CGFloat = FormMetrics.width + 24
    /// Narrowest window that shows the expanded sidebar and a whole form column.
    static let minWindowWidth: CGFloat = sidebarExpanded + 1 + 2 * detailPadding + contentWidth
}

/// Advanced: a collapsible sidebar of sections with the selected section's
/// form centered on the right.
private struct AdvancedView: View {
    let model: MainTabsModel

    private var collapsed: Bool { model.advancedSidebarCollapsed }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            section
                .frame(maxWidth: AdvancedLayout.contentWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, AdvancedLayout.detailPadding)
                .padding(.bottom, 12)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.snappy) { model.toggleAdvancedSidebar() }
            } label: {
                Image(systemName: "sidebar.left")
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(collapsed ? "Show sidebar" : "Hide sidebar")
            .accessibilityLabel(collapsed ? "Show sidebar" : "Hide sidebar")
            .accessibilityIdentifier("advanced-sidebar-toggle")
            .keyboardShortcut("s", modifiers: [.command, .option])
            .padding(.bottom, 6)

            ForEach(AdvancedSection.allCases, id: \.self) { item in
                row(item)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .frame(width: collapsed ? AdvancedLayout.sidebarCollapsed : AdvancedLayout.sidebarExpanded)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ item: AdvancedSection) -> some View {
        let selected = model.advancedSection == item
        return Button {
            model.selectAdvancedSection(item)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .frame(width: 20)
                if !collapsed {
                    Text(item.label)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.label)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var section: some View {
        let models = model.models
        switch model.advancedSection {
        case .accounts:
            if let connect = models.connectModel { AccountsSectionView(connect: connect) }
        case .capacity:
            if let capacity = models.capacityModel, let mac = models.macToolsModel,
                let runtimes = models.runtimesModel
            {
                CapacityView(model: capacity, mac: mac, runtimes: runtimes)
            }
        case .routing:
            if let runtimes = models.runtimesModel { RuntimesView(model: runtimes) }
        case .containers:
            if let containers = models.containersModel { ContainersView(model: containers) }
        case .toolchains:
            if let toolchains = models.toolchainsModel { ToolchainsView(model: toolchains) }
        case .benchmarks:
            if let benchmarks = models.benchmarksModel { BenchmarksView(model: benchmarks) }
        case .app:
            AppSectionView(model: models.appModel)
        }
    }
}

/// The log viewer sheet: the searchable log over Open-folder / Done buttons.
/// The ring buffer is re-read every second while the sheet is up.
private struct LogsSheet: View {
    let model: LogsModel
    let openFolder: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            LogsView(model: model)
            HStack {
                Button("Open logs folder", action: openFolder)
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minWidth: 480, idealWidth: 640, minHeight: 320, idealHeight: 460)
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
