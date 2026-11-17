import KinhinKit
import SwiftUI

/// The Connect form: a row of forge chips ("Where does your code live?") and
/// one uniform card per selected forge — token field with Connect/Replace,
/// server address for self-hostable forges, scope picker, and the forge's
/// token-requirements hint.
struct ConnectView: View {
    @Bindable var model: ConnectModel
    /// First-run setup hides "More accounts"; the Accounts page shows it.
    var showsMoreAccounts = true
    /// The wizard keeps the fixed form width; the Accounts page fills its column.
    var layout: CardLayout = .form

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            selector
            ForEach(ConnectModel.allForges, id: \.self) { forge in
                if let card = model.card(for: forge) {
                    ForgeCard(model: card, layout: layout, onDeselect: { model.requestDeselect(forge) })
                        .transition(.opacity)
                }
            }
            if showsMoreAccounts { MoreAccountsCard(model: model.accounts, layout: layout) }
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
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Where does your code live?").typeStyle(.emphasis)
            HintText("Select every forge kinhin should serve; each gets its own card below.")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280), spacing: Spacing.sm, alignment: .leading)],
                alignment: .leading, spacing: Spacing.sm
            ) {
                ForEach(ConnectModel.allForges, id: \.self) { forge in
                    chip(forge)
                }
            }
        }
    }

    private func chip(_ forge: ForgeID) -> some View {
        let on = model.isSelected(forge)
        let maturity = MaturityTable.maturity(of: forge)
        return Button {
            model.setSelected(!on, for: forge)
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: on ? "checkmark" : "circle")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(on ? Palette.accentText : Palette.secondaryText)
                    .frame(width: 14)
                ForgeIconView(forge: forge, size: 14)
                Text(forge.displayName).typeStyle(.body).fontWeight(.medium).lineLimit(1).layoutPriority(1)
                if maturity != .liveTested {
                    Chip(maturity.isExperimental ? "Experimental" : "Untested", tone: .warn)
                }
            }
            .foregroundStyle(Palette.primaryText)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.lg).fill(on ? Palette.accent.opacity(0.12) : Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg)
                    .strokeBorder(on ? Palette.accent : Palette.separator, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connect-forge-\(forge.rawValue)")
        .accessibilityLabel("\(forge.displayName)\(maturity.pickerSuffix)")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}
