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

/// Advanced: a segmented section picker over the section's form.
private struct AdvancedView: View {
    let model: MainTabsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(
                "Advanced sections",
                selection: Binding(get: { model.advancedSection }, set: { model.selectAdvancedSection($0) })
            ) {
                ForEach(AdvancedSection.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Advanced sections")
            .frame(width: 560)
            .padding(.leading, 4)

            section
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var section: some View {
        let models = model.models
        switch model.advancedSection {
        case .accounts:
            if let connect = models.connectModel { AccountsSectionView(connect: connect) }
        case .capacity:
            if let capacity = models.capacityModel, let mac = models.macToolsModel {
                CapacityView(model: capacity, mac: mac)
            }
        case .routing:
            if let runtimes = models.runtimesModel { RuntimesView(model: runtimes) }
        case .containers:
            if let containers = models.containersModel { ContainersView(model: containers) }
        case .toolchains:
            if let toolchains = models.toolchainsModel { ToolchainsView(model: toolchains) }
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
