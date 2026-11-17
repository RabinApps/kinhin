import KinhinKit
import SwiftUI

/// One uniform card per forge, editing that forge's conventional `accounts:`
/// entry (`github`, `gitea`, `forgejo`, `gitlab`).
struct ForgeCard: View {
    @Bindable var model: ForgeConnectionModel
    var layout: CardLayout = .form
    var onDeselect: () -> Void
    @FocusState private var focus: ForgeConnectionModel.Field?

    var body: some View {
        Card(
            title: Text(verbatim: model.forge.displayName), forge: model.forge, layout: layout,
            trailing: {
                Button("Remove") { onDeselect() }
                    .controlSize(.small)
                    .accessibilityIdentifier("connect-\(model.forge.rawValue)-remove")
            }
        ) {
            StatusText(verbatim: model.status.text, style: model.status.style)
            HStack(alignment: .bottom, spacing: Spacing.md) {
                if model.showsInstance { serverField }
                tokenField
                Button(model.buttonTitle) { model.connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.checking)
                    .accessibilityIdentifier("connect-\(model.forge.rawValue)")
            }
            scopeField
            HintText(
                model.forge == .github
                    ? "Use owner/name for one repo, or just an org name to serve every repo in it. The token is kept in your Keychain, never in a file. GitHub is hosted at github.com by default. Add an enterprise host only for GHES (https://github.example.com) or GHEC data residency (https://acme.ghe.com)."
                    : "Use a path for one repository (or project), or a group/org name to serve everything under it. The token is kept in your Keychain, never in a file."
            )
            TokenRequirementsView(
                requirements: model.requirements, expandOnError: model.status.style == .error)
        }
    }

    private var serverField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HintText("Server address")
            // A verbatim prompt: a string-literal title is parsed as
            // markdown, which turns the URL placeholder into a link.
            TextField("", text: $model.instance, prompt: Text(verbatim: model.instancePlaceholder))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180)
                .disabled(model.instanceEnabled == false)
                .focused($focus, equals: .instance(model.forge))
                .onSubmit { model.commit() }
                .accessibilityIdentifier("connect-\(model.forge.rawValue)-instance")
                .accessibilityLabel("\(model.forge.displayName) server address")
        }
    }

    private var tokenField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HintText("Access token")
            SecureField("Paste a \(model.forge.displayName) access token", text: $model.tokenText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180)
                .focused($focus, equals: .token(model.forge))
                .onSubmit { model.connect() }
                .accessibilityIdentifier("connect-\(model.forge.rawValue)-token")
                .accessibilityLabel("\(model.forge.displayName) access token")
        }
    }

    private var scopeField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(model.scopeLabel).typeStyle(.caption).foregroundStyle(.secondary)
            ComboField(
                text: $model.scope,
                items: model.repos,
                placeholder: ForgeConnectionModel.scopePlaceholder(enabled: model.scopeEnabled, forge: model.forge),
                isEnabled: model.scopeEnabled,
                identifier: "connect-\(model.forge.rawValue)-scope",
                accessibilityLabel: String(
                    localized: "\(model.forge.displayName) repository or organization to serve", bundle: .l10n,
                    comment: "VoiceOver label of the repository combo box; %@ is a forge name"),
                onCommit: { model.commit() }
            )
            .frame(maxWidth: 340)
        }
    }
}
