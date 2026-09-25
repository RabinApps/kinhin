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

            HStack(spacing: 8) {
                Button(model.skipTitle) { model.skip() }
                    .controlSize(.small)
                Spacer()
                Button("Back") { model.back() }
                    .disabled(!model.canGoBack)
                Button(model.nextTitle) { model.next() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canContinue)
            }
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .connect:
            ScrollView { ConnectView(model: model.connect).padding(.bottom, 8) }
        case .mac:
            ScrollView { MacToolsView(model: model.mac).padding(.bottom, 8) }
        case .toolchains:
            ToolchainsView(model: model.toolchains, appliesOnReturn: false, inset: 0)
        case .start:
            Text(model.summaryText)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(width: FormMetrics.width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
