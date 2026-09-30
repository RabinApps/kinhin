import KinhinKit
import SwiftUI

/// The Connect form: a row of forge chips ("Where does your code live?") and
/// one uniform card per selected forge — token field with Connect/Replace,
/// server address for self-hostable forges, scope picker, and the forge's
/// token-requirements hint.
struct ConnectView: View {
    @Bindable var model: ConnectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            selector
            ForEach(ConnectModel.allForges, id: \.self) { forge in
                if let card = model.card(for: forge) {
                    ForgeCard(model: card, onDeselect: { model.requestDeselect(forge) })
                        .transition(.opacity)
                }
            }
            MoreAccountsCard(model: model.accounts)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.default, value: model.selected)
        .alert(
            "Stop serving \(model.pendingDeselect?.displayName ?? "")?",
            isPresented: Binding(
                get: { model.pendingDeselect != nil },
                set: { presenting in
                    if !presenting { model.cancelDeselect() }
                })
        ) {
            // Captured when the alert is presented: the dismissal binding can
            // clear `pendingDeselect` before the button action runs.
            let staged = model.pendingDeselect
            Button("Remove account and token", role: .destructive) { model.confirmDeselect(staged) }
            Button("Cancel", role: .cancel) { model.cancelDeselect() }
        } message: {
            Text("This removes its account and token.")
        }
    }

    private var selector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where does your code live?").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                ForEach(ConnectModel.allForges, id: \.self) { forge in
                    chip(forge)
                }
            }
            HintText("Select every forge kinhin should serve; each gets its own card below.")
        }
    }

    private func chip(_ forge: ForgeID) -> some View {
        let on = model.isSelected(forge)
        return Button {
            model.setSelected(!on, for: forge)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                Text(forge.displayName).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? Color.primary : Color.secondary)
        .accessibilityIdentifier("connect-forge-\(forge.rawValue)")
        .accessibilityLabel("\(forge.displayName)")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}
