import SwiftUI

/// The first-run wizard: a step header, the current step's form, and a
/// Skip / Back / Continue footer.
struct WizardView: View {
    let model: WizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                progress
                Text(verbatim: model.step.title)
                    .typeStyle(.display)
                    .accessibilityAddTraits(.isHeader)
                HintText(verbatim: model.step.subtitle)
                    .lineLimit(3)
            }
            .padding(.top, Spacing.xl)

            content
                .padding(.top, Spacing.md + 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.lg)
        }
        .padding(.horizontal, Spacing.xxl)
    }

    /// Three numbered chips (the current one filled) and "Step N of 3 — title".
    private var progress: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(WizardModel.Step.allCases, id: \.rawValue) { step in
                Chip(
                    verbatim: "\(step.rawValue + 1)", tone: step == model.step ? .accent : .neutral,
                    solid: step == model.step
                )
                .accessibilityHidden(true)
            }
            Text(verbatim: model.header).typeStyle(.emphasis)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wizard-progress")
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
                    .accessibilityIdentifier("wizard-open-config")
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
            .frame(maxWidth: 420, alignment: .trailing)
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
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    Card(title: "Review", layout: .fill) {
                        Text(verbatim: model.summaryText)
                            .typeStyle(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Spacing.md)
                            .background(Palette.grouped, in: RoundedRectangle(cornerRadius: Radius.lg))
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.lg)
                                    .strokeBorder(Palette.separator, lineWidth: 1))
                    }
                    Toggle("Start the fleet automatically whenever kinhin opens", isOn: $model.autoStartFleet)
                        .toggleStyle(.switch)
                        .padding(.horizontal, Spacing.md)
                    tuneIt(model: model)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.bottom, Spacing.sm)
            }
        }
    }

    /// Optional knobs, closed by default: the defaults are fine.
    private func tuneIt(model: WizardModel) -> some View {
        @Bindable var model = model
        return Card(layout: .fill) {
            DisclosureGroup(isExpanded: $model.tuneItExpanded) {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    if model.runtimes.showsBudget {
                        BudgetCard(model: model.runtimes)
                    } else {
                        StatusText(
                            text:
                                "Only one runtime is enabled, so there's nothing to split. Enable another on the previous step (Docker, Apple container or tart) to divide this Mac's capacity.",
                            style: .secondary
                        )
                    }
                    Text("Toolchains").typeStyle(.emphasis)
                    ToolchainsGuideView()
                }
                .padding(.top, Spacing.sm)
            } label: {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Tune it (optional)").typeStyle(.emphasis)
                    HintText("Split your capacity and see how toolchains work.")
                }
            }
        }
        .accessibilityIdentifier("wizard-tune-it")
    }
}
