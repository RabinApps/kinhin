import KinhinKit
import SwiftUI

/// The Connect form: a GitHub card (token → repo or org) and an optional
/// self-hosted Gitea card.
struct ConnectView: View {
    @Bindable var model: ConnectModel
    @FocusState private var focus: ConnectModel.Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            githubCard
            giteaCard
            AccountsSection(model: model.accounts)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: model.focusRequest) { _, request in
            guard let request else { return }
            focus = request
            model.focusRequest = nil
        }
        // The Gitea server commits when the user leaves the field, as the
        // scope does.
        .onChange(of: focus) { old, new in
            if old == .giteaInstance, new != .giteaInstance { model.commitGitea() }
        }
    }

    private var githubCard: some View {
        FormCard(title: "GitHub") {
            StatusText(text: model.githubStatus.text, style: model.githubStatus.style)
            HStack(spacing: 8) {
                SecureField("Paste a personal access token", text: $model.githubTokenText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 300)
                    .focused($focus, equals: .githubToken)
                    .onSubmit { model.connectGitHub() }
                    .accessibilityIdentifier("connect-github-token")
                    .accessibilityLabel("GitHub access token")
                Button(model.githubButtonTitle) { model.connectGitHub() }
                    .disabled(model.githubChecking)
                    .accessibilityIdentifier("connect-github")
            }
            HStack(spacing: 8) {
                Text("Repository or org").font(.system(size: 12))
                ComboField(
                    text: $model.githubRepo, items: model.githubRepos,
                    placeholder: ConnectModel.repoPlaceholder(enabled: model.githubRepoEnabled),
                    isEnabled: model.githubRepoEnabled, identifier: "connect-github-repo",
                    accessibilityLabel: "GitHub repository or organization to serve",
                    onCommit: { model.commitGitHubRepo() }
                )
                .frame(width: 300)
            }
            HintText(
                "Use owner/name for one repo, or just an org name to serve every repo in it. The token is kept in your Keychain, never in a file."
            )
            TokenRequirementsView(
                requirements: model.githubRequirements, expandOnError: model.githubStatus.style == .error)
        }
    }

    private var giteaCard: some View {
        FormCard(title: "Gitea (optional)") {
            Toggle(
                "Also serve a self-hosted Gitea",
                isOn: Binding(get: { model.giteaEnabled }, set: { model.setGiteaEnabled($0) })
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .accessibilityIdentifier("connect-gitea-toggle")

            if model.giteaEnabled {
                StatusText(text: model.giteaStatus.text, style: model.giteaStatus.style)
                HStack(spacing: 8) {
                    Text("Server").font(.system(size: 12))
                    // A verbatim prompt: a string-literal title is parsed as markdown, which
                    // turns the URL placeholder into a link.
                    TextField("", text: $model.giteaInstance, prompt: Text(verbatim: "https://gitea.example.com"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                        .focused($focus, equals: .giteaInstance)
                        .onSubmit { model.commitGitea() }
                        .accessibilityIdentifier("connect-gitea-instance")
                        .accessibilityLabel("Gitea server address")
                }
                HStack(spacing: 8) {
                    SecureField("Paste a Gitea access token", text: $model.giteaTokenText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 300)
                        .focused($focus, equals: .giteaToken)
                        .onSubmit { model.connectGitea() }
                        .accessibilityIdentifier("connect-gitea-token")
                        .accessibilityLabel("Gitea access token")
                    Button(model.giteaButtonTitle) { model.connectGitea() }
                        .disabled(model.giteaChecking)
                        .accessibilityIdentifier("connect-gitea")
                }
                HStack(spacing: 8) {
                    Text("Repository or org").font(.system(size: 12))
                    ComboField(
                        text: $model.giteaScope, items: model.giteaRepos,
                        placeholder: ConnectModel.repoPlaceholder(enabled: model.giteaScopeEnabled),
                        isEnabled: model.giteaScopeEnabled, identifier: "connect-gitea-scope",
                        accessibilityLabel: "Gitea repository or organization to serve",
                        onCommit: { model.commitGitea() }
                    )
                    .frame(width: 300)
                }
                TokenRequirementsView(
                    requirements: model.giteaRequirements, expandOnError: model.giteaStatus.style == .error)
            }
        }
    }
}
