import KinhinKit
import SwiftUI

/// The main window's content: one sidebar of sections beside the selected section's page, with the pipeline, workflow
/// test, video and sponsor sheets. While first-run setup is unfinished there is no sidebar and the page is the Setup
/// wizard. Navigation state lives in `MainTabsModel`; each page is the existing per-domain view.
struct MainShellView: View {
    @Bindable var model: MainTabsModel

    var body: some View {
        HStack(spacing: 0) {
            if !model.isGatedBySetup {
                SidebarView(model: model)
                Divider()
            }
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.grouped)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .pipeline(let vmID):
                if let pipeline = model.models.pipelineModel, pipeline.vmID == vmID {
                    PipelineView(model: pipeline, onClose: { model.dismissSheet() })
                }
            case .workflowTest:
                if let model = model.models.workflowTestModel {
                    WorkflowTestView(model: model, onClose: { self.model.dismissSheet() })
                }
            case .videos:
                if let videos = model.models.videosModel {
                    VideosView(model: videos, onClose: { self.model.dismissSheet() })
                }
            case .sponsor:
                SponsorSheet(close: { model.dismissSheet() })
            }
        }
    }

    @ViewBuilder
    private var page: some View {
        if model.isGatedBySetup {
            if let wizard = model.models.wizardModel {
                WizardView(model: wizard)
                    .padding(.top, ShellLayout.titlebarClearance - Spacing.sm)
            }
        } else {
            SectionPage(model: model)
        }
    }
}

/// The selected section's page: its content in a centered column, below the title bar.
private struct SectionPage: View {
    let model: MainTabsModel

    var body: some View {
        content
            .padding(.horizontal, Spacing.page)
            .padding(.top, ShellLayout.titlebarClearance - Spacing.sm)
            .padding(.bottom, Spacing.md)
            .frame(maxWidth: ShellLayout.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        let models = model.models
        switch model.selectedSection {
        case .fleet:
            FleetView(model: models.fleetModel)
        case .runtimes:
            if let capacity = models.capacityModel, let mac = models.macToolsModel,
                let runtimes = models.runtimesModel
            {
                RuntimesPage(capacity: capacity, mac: mac, runtimes: runtimes)
            }
        case .accounts:
            if let connect = models.connectModel {
                PageHeaderStack(title: MainSection.accounts.label) { AccountsSectionView(connect: connect) }
            }
        case .toolchains:
            if let toolchains = models.toolchainsModel {
                PageHeaderStack(title: MainSection.toolchains.label) { ToolchainsView(model: toolchains) }
            }
        case .diagnostics:
            DiagnosticsPage(model: model)
        case .settings:
            PageHeaderStack(title: MainSection.settings.label) {
                AppSectionView(
                    model: models.appModel, telemetry: models.telemetryModel, alerts: models.alertsModel,
                    openSupport: { model.present(.sponsor) })
            }
        }
    }
}
