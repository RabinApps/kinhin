import SwiftUI

/// The first-run wizard: a step header, the current step's form, and a
/// Skip / Back / Continue footer.
struct WizardView: View {
    let model: WizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.header).font(.system(size: 22, weight: .bold))
                Text(model.step.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 20)

            content
                .padding(.top, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer
                .padding(.top, 12)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 24)
    }

    /// Skip / Open config / Back / Continue, with what blocks Continue said
    /// beside the disabled button instead of leaving it silently inert.
    private var footer: some View {
        HStack(spacing: 8) {
            if model.canSkip {
                Button(model.skipTitle) { model.skip() }
                    .controlSize(.small)
            }
            if model.showsOpenConfigButton {
                Button("Open config.yaml") { model.openConfig?() }
                    .controlSize(.small)
            }
            Spacer()
            if !model.canContinue {
                blockerNote
            }
            Button("Back") { model.back() }
                .disabled(!model.canGoBack)
            Button(model.nextTitle) { model.next() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canContinue)
        }
    }

    private var blockerNote: some View {
        let blockers = model.currentBlockers
        return StatusText(verbatim: blockers.joined(separator: " "), style: .warn)
            .lineLimit(3)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 340, alignment: .trailing)
            .accessibilityIdentifier("wizard-blockers")
            .accessibilityLabel(
                String(
                    localized: "Cannot continue yet: \(blockers.joined(separator: " "))", bundle: .l10n,
                    comment: "VoiceOver label for the disabled Continue button's note; %@ lists what blocks it"))
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .connect:
            ScrollView { ConnectView(model: model.connect, showsMoreAccounts: false).padding(.bottom, 8) }
        case .mac:
            ScrollView { MacToolsView(model: model.mac).padding(.bottom, 8) }
        case .review:
            @Bindable var model = model
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(verbatim: model.summaryText)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Start the fleet automatically whenever kinhin opens", isOn: $model.autoStartFleet)
                        .accessibilityLabel("Start the fleet automatically whenever kinhin opens")
                    tuneIt(model: model)
                }
                .frame(width: FormMetrics.width, alignment: .topLeading)
                .padding(.bottom, 8)
            }
        }
    }

    /// Optional knobs, closed by default: the defaults are fine.
    private func tuneIt(model: WizardModel) -> some View {
        @Bindable var model = model
        return DisclosureGroup(isExpanded: $model.tuneItExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Split your capacity").font(.system(size: 12, weight: .semibold))
                if model.runtimes.showsBudget {
                    BudgetCard(model: model.runtimes)
                } else {
                    StatusText(
                        text:
                            "Only one runtime is enabled, so there's nothing to split. Enable another on the previous step (Docker, Apple container or tart) to divide this Mac's capacity.",
                        style: .secondary
                    )
                }
                Text("Toolchains").font(.system(size: 12, weight: .semibold))
                ToolchainsGuideView()
            }
            .padding(.top, 8)
        } label: {
            Text("Tune it (optional)").font(.system(size: 13, weight: .semibold))
        }
        .accessibilityIdentifier("wizard-tune-it")
    }
}
