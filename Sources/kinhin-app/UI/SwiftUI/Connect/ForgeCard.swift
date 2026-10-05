import KinhinKit
import SwiftUI

/// One uniform card per forge, editing that forge's conventional `accounts:`
/// entry (`github`, `gitea`, `forgejo`, `gitlab`).
struct ForgeCard: View {
    @Bindable var model: ForgeConnectionModel
    var onDeselect: () -> Void
    @FocusState private var focus: ForgeConnectionModel.Field?

    var body: some View {
        FormCard(title: model.forge.displayName, forge: model.forge) {
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
                    ? "Use owner/name for one repo, or just an org name to serve every repo in it. The token is kept in your Keychain, never in a file. GitHub is hosted at github.com by default. Add an enterprise host only for GHES (https://github.example.com) or GHEC data residency (https://acme.ghe.com)."
                    : "Use a path for one repository (or project), or a group/org name to serve everything under it. The token is kept in your Keychain, never in a file."
            )
            TokenRequirementsView(
                requirements: model.requirements, expandOnError: model.status.style == .error)
        }
    }
}
