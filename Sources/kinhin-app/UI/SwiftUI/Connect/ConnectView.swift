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
            AccountsSection(model: model.accounts)
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

/// One uniform card per forge. GitHub → `repo:`, Gitea/Forgejo → `gitea:` /
/// `forgejo:`, GitLab → the `accounts:` entry named `gitlab`.
struct ForgeCard: View {
    @Bindable var model: ForgeConnectionModel
    var onDeselect: () -> Void
    @FocusState private var focus: ForgeConnectionModel.Field?

    var body: some View {
        FormCard(title: model.forge.displayName) {
            HStack {
                StatusText(text: model.status.text, style: model.status.style)
                Spacer()
                Button("Remove") { onDeselect() }
                    .controlSize(.small)
                    .accessibilityIdentifier("connect-\(model.forge.rawValue)-remove")
            }
            if model.showsInstance {
                HStack(spacing: 8) {
                    Text("Server").font(.system(size: 12))
                    // A verbatim prompt: a string-literal title is parsed as
                    // markdown, which turns the URL placeholder into a link.
                    TextField(
                        "",
                        text: $model.instance,
                        prompt: Text(verbatim: model.instancePlaceholder)
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .disabled(model.instanceEnabled == false)
                    .focused($focus, equals: .instance(model.forge))
                    .onSubmit { model.commit() }
                    .accessibilityIdentifier("connect-\(model.forge.rawValue)-instance")
                    .accessibilityLabel("\(model.forge.displayName) server address")
                }
            }
            HStack(spacing: 8) {
                SecureField("Paste a \(model.forge.displayName) access token", text: $model.tokenText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 300)
                    .focused($focus, equals: .token(model.forge))
                    .onSubmit { model.connect() }
                    .accessibilityIdentifier("connect-\(model.forge.rawValue)-token")
                    .accessibilityLabel("\(model.forge.displayName) access token")
                Button(model.buttonTitle) { model.connect() }
                    .disabled(model.checking)
                    .accessibilityIdentifier("connect-\(model.forge.rawValue)")
            }
            HStack(spacing: 8) {
                Text(model.scopeLabel).font(.system(size: 12))
                ComboField(
                    text: $model.scope,
                    items: model.repos,
                    placeholder: ForgeConnectionModel.scopePlaceholder(enabled: model.scopeEnabled, forge: model.forge),
                    isEnabled: model.scopeEnabled,
                    identifier: "connect-\(model.forge.rawValue)-scope",
                    accessibilityLabel: "\(model.forge.displayName) repository or organization to serve",
                    onCommit: { model.commit() }
                )
                .frame(width: 300)
            }
            HintText(
                model.forge == .github
                    ? "Use owner/name for one repo, or just an org name to serve every repo in it. The token is kept in your Keychain, never in a file."
                    : "Use a path for one repository (or project), or a group/org name to serve everything under it. The token is kept in your Keychain, never in a file."
            )
            TokenRequirementsView(
                requirements: model.requirements, expandOnError: model.status.style == .error)
        }
    }
}
