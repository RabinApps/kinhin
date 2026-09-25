import AppKit
import KinhinKit

/// The one place an account is connected: a GitHub card (token → repo or org)
/// and an optional self-hosted Gitea card. Used by both the onboarding
/// wizard and the Setup tab, so the same setting is never entered twice.
///
/// - Pasting a token and pressing Connect verifies it by listing the repos it
///   can see, stores it in the Keychain, and fills the repo picker.
/// - The repo picker is an editable combo box: choose from the list, or type
///   `owner/name` (one repo) or an org name (every repo in the org).
/// - Config writes go through `GeneralConfigEditor` (comments preserved,
///   engine-validated).
@MainActor
final class ConnectFormViewController: NSViewController, NSComboBoxDelegate, NSTextFieldDelegate {
    /// Persists a token (and live-swaps it into a running engine). Defaults
    /// to a plain Keychain save; the app injects the live-swap version.
    var saveToken: (ForgeID, String) async throws -> Void = { forge, token in
        try KeychainTokenStore.save(token, forge: forge)
    }
    /// The config file this form edits (tests point it at a scratch file).
    var configURL: URL = Paths.config
    /// Whether a token is stored for a forge (tests stub this out so they
    /// never touch the real Keychain).
    var hasStoredToken: @Sendable (ForgeID) -> Bool = { KeychainTokenStore.load(forge: $0) != nil }
    /// Fired after any successful token or config change.
    var onChanged: (() -> Void)?

    /// True once at least one forge is fully connected: GitHub (stored token
    /// + real repo/org) or Gitea (stored token + server + scope). Either one
    /// alone is enough to run a fleet.
    var isConnected: Bool { githubConnected || giteaConnected }
    private var githubConnected = false
    private var giteaConnected = false
    private var giteaTokenStored = false

    private let stack = NSStackView()

    // GitHub
    private let githubStatus = NSTextField(labelWithString: "Not connected yet.")
    private let githubToken = NSSecureTextField(frame: .zero)
    private let githubConnect = NSButton(title: "Connect", target: nil, action: nil)
    private let githubRepo = NSComboBox(frame: .zero)

    // Gitea
    private let giteaToggle = NSButton(checkboxWithTitle: "Also serve a self-hosted Gitea", target: nil, action: nil)
    private let giteaBody = NSStackView()
    private let giteaStatus = NSTextField(labelWithString: "Not connected yet.")
    private let giteaInstance = NSTextField(frame: .zero)
    private let giteaToken = NSSecureTextField(frame: .zero)
    private let giteaConnect = NSButton(title: "Connect", target: nil, action: nil)
    private let giteaScope = NSComboBox(frame: .zero)

    private var githubTokenStored = false
    private var lastWrittenRepo = ""
    private var lastWrittenGitea: GeneralConfigEditor.Snapshot.Gitea?

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("created in code") }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(buildGitHubCard())
        stack.addArrangedSubview(buildGiteaCard())

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        view = container
        reload()
    }

    // MARK: Construction

    private func buildGitHubCard() -> NSView {
        let (card, column) = FormKit.card(title: "GitHub")

        githubStatus.font = .systemFont(ofSize: 11)
        githubStatus.textColor = .secondaryLabelColor
        column.addArrangedSubview(githubStatus)

        githubToken.placeholderString = "Paste a personal access token"
        githubToken.identifier = NSUserInterfaceItemIdentifier("connect-github-token")
        githubToken.setAccessibilityLabel("GitHub access token")
        githubToken.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        githubToken.target = self
        githubToken.action = #selector(connectGitHub)
        githubConnect.bezelStyle = .rounded
        githubConnect.target = self
        githubConnect.action = #selector(connectGitHub)
        githubConnect.identifier = NSUserInterfaceItemIdentifier("connect-github")
        column.addArrangedSubview(FormKit.row([githubToken, githubConnect]))

        githubRepo.placeholderString = "owner/name, or an org name"
        githubRepo.identifier = NSUserInterfaceItemIdentifier("connect-github-repo")
        githubRepo.setAccessibilityLabel("GitHub repository or organization to serve")
        githubRepo.completes = true
        githubRepo.numberOfVisibleItems = 12
        setRepoFieldEnabled(githubRepo, enabled: false)
        githubRepo.delegate = self
        githubRepo.target = self
        githubRepo.action = #selector(githubRepoCommitted)
        githubRepo.widthAnchor.constraint(equalToConstant: 300).isActive = true
        column.addArrangedSubview(FormKit.row([FormKit.label("Repository or org"), githubRepo]))
        column.addArrangedSubview(FormKit.hint("Use owner/name for one repo, or just an org name to serve every repo in it. The token is kept in your Keychain, never in a file."))
        return card
    }

    private func buildGiteaCard() -> NSView {
        let (card, column) = FormKit.card(title: "Gitea (optional)")

        giteaToggle.target = self
        giteaToggle.action = #selector(giteaToggled)
        giteaToggle.identifier = NSUserInterfaceItemIdentifier("connect-gitea-toggle")
        column.addArrangedSubview(giteaToggle)

        giteaBody.orientation = .vertical
        giteaBody.alignment = .leading
        giteaBody.spacing = 8
        giteaBody.detachesHiddenViews = true
        giteaBody.isHidden = true

        giteaStatus.font = .systemFont(ofSize: 11)
        giteaStatus.textColor = .secondaryLabelColor
        giteaBody.addArrangedSubview(giteaStatus)

        giteaInstance.placeholderString = "https://gitea.example.com"
        giteaInstance.identifier = NSUserInterfaceItemIdentifier("connect-gitea-instance")
        giteaInstance.setAccessibilityLabel("Gitea server address")
        giteaInstance.delegate = self
        giteaInstance.widthAnchor.constraint(equalToConstant: 300).isActive = true
        giteaBody.addArrangedSubview(FormKit.row([FormKit.label("Server"), giteaInstance]))

        giteaToken.placeholderString = "Paste a Gitea access token"
        giteaToken.identifier = NSUserInterfaceItemIdentifier("connect-gitea-token")
        giteaToken.setAccessibilityLabel("Gitea access token")
        giteaToken.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        giteaToken.target = self
        giteaToken.action = #selector(connectGitea)
        giteaConnect.bezelStyle = .rounded
        giteaConnect.target = self
        giteaConnect.action = #selector(connectGitea)
        giteaConnect.identifier = NSUserInterfaceItemIdentifier("connect-gitea")
        giteaBody.addArrangedSubview(FormKit.row([giteaToken, giteaConnect]))

        giteaScope.placeholderString = "owner/name, or an org name"
        giteaScope.identifier = NSUserInterfaceItemIdentifier("connect-gitea-scope")
        giteaScope.setAccessibilityLabel("Gitea repository or organization to serve")
        giteaScope.completes = true
        setRepoFieldEnabled(giteaScope, enabled: false)
        giteaScope.delegate = self
        giteaScope.target = self
        giteaScope.action = #selector(giteaScopeCommitted)
        giteaScope.widthAnchor.constraint(equalToConstant: 300).isActive = true
        giteaBody.addArrangedSubview(FormKit.row([FormKit.label("Repository or org"), giteaScope]))

        column.addArrangedSubview(giteaBody)
        return card
    }

    // MARK: Loading

    /// Re-reads config + Keychain (off the main thread — a Keychain read can
    /// block on a system prompt) and refreshes both cards.
    func reload() {
        let yaml = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let snapshot = try? GeneralConfigEditor.snapshot(from: yaml)
        Task { [weak self] in
            let probe = self?.hasStoredToken ?? { _ in false }
            let tokens = await Task.detached { (probe(.github), probe(.gitea)) }.value
            self?.render(snapshot: snapshot, hasGitHubToken: tokens.0, hasGiteaToken: tokens.1)
        }
    }

    private func render(snapshot: GeneralConfigEditor.Snapshot?, hasGitHubToken: Bool, hasGiteaToken: Bool) {
        let repo = snapshot?.repo ?? ""
        let configuredRepo = (repo == ConfigLoader.templateRepo) ? "" : repo
        lastWrittenRepo = configuredRepo
        githubRepo.stringValue = configuredRepo
        githubStatus.stringValue = hasGitHubToken ? "Token stored in your Keychain ✓ — paste a new one only to replace it." : "Not connected yet."
        githubStatus.textColor = hasGitHubToken ? .secondaryLabelColor : .systemOrange
        githubConnect.title = hasGitHubToken ? "Replace" : "Connect"
        githubTokenStored = hasGitHubToken
        setRepoFieldEnabled(githubRepo, enabled: hasGitHubToken)
        githubConnected = hasGitHubToken && !configuredRepo.isEmpty

        let gitea = snapshot?.gitea
        lastWrittenGitea = gitea
        giteaTokenStored = hasGiteaToken
        giteaConnected = hasGiteaToken && gitea != nil
        giteaToggle.state = gitea != nil ? .on : (giteaBody.isHidden ? .off : giteaToggle.state)
        giteaBody.isHidden = giteaToggle.state != .on
        if let gitea {
            giteaInstance.stringValue = gitea.instance
            giteaScope.stringValue = gitea.scope
        }
        giteaStatus.stringValue = hasGiteaToken ? "Token stored in your Keychain ✓ — paste a new one only to replace it." : "Not connected yet."
        giteaStatus.textColor = hasGiteaToken ? .secondaryLabelColor : .systemOrange
        giteaConnect.title = hasGiteaToken ? "Replace" : "Connect"
        setRepoFieldEnabled(giteaScope, enabled: hasGiteaToken)

        if hasGitHubToken { Task { await listRepos(forge: .github, token: nil) } }
        if hasGiteaToken, gitea != nil { Task { await listRepos(forge: .gitea, token: nil) } }
    }

    /// A repository can only be chosen once its forge is connected: without a
    /// token there is nothing to list or verify against.
    fileprivate func setRepoFieldEnabled(_ combo: NSComboBox, enabled: Bool) {
        combo.isEnabled = enabled
        combo.placeholderString = enabled ? "owner/name, or an org name" : "Connect first to choose a repository"
    }

    // MARK: Connect

    @objc private func connectGitHub() {
        let typed = githubToken.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            githubToken.becomeFirstResponderSelecting()
            return
        }
        githubConnect.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            defer { self.githubConnect.isEnabled = true }
            self.githubStatus.stringValue = "Checking the token…"
            self.githubStatus.textColor = .secondaryLabelColor
            guard await self.listRepos(forge: .github, token: typed) else { return }
            do {
                try await self.saveToken(.github, typed)
                self.githubToken.stringValue = ""
                self.githubConnect.title = "Replace"
                self.onChanged?()
                await self.verifyPermission(scope: self.githubRepo.stringValue.trimmingCharacters(in: .whitespaces))
            } catch {
                self.githubStatus.stringValue = "Couldn't save the token — \(error.localizedDescription)"
                self.githubStatus.textColor = .systemRed
            }
        }
    }

    @objc private func connectGitea() {
        let typed = giteaToken.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !giteaInstance.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else {
            giteaStatus.stringValue = "Enter your Gitea server address first."
            giteaStatus.textColor = .systemOrange
            return
        }
        guard !typed.isEmpty else {
            giteaToken.becomeFirstResponderSelecting()
            return
        }
        giteaConnect.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            defer { self.giteaConnect.isEnabled = true }
            self.giteaStatus.stringValue = "Checking the token…"
            self.giteaStatus.textColor = .secondaryLabelColor
            guard await self.listRepos(forge: .gitea, token: typed) else { return }
            do {
                try await self.saveToken(.gitea, typed)
                self.giteaToken.stringValue = ""
                self.commitGitea()
                self.onChanged?()
                // Gitea has no runner-management token model; no probe needed.
            } catch {
                self.giteaStatus.stringValue = "Couldn't save the token — \(error.localizedDescription)"
                self.giteaStatus.textColor = .systemRed
            }
        }
    }

    /// Lists the repos a token can see and fills the matching picker. `token`
    /// nil → use the stored one. Returns false (with a message) on failure.
    @discardableResult
    private func listRepos(forge: ForgeID, token: String?) async -> Bool {
        let resolved: String? = if let token { token } else {
            await Task.detached { KeychainTokenStore.load(forge: forge) }.value
        }
        guard let resolved else { return false }
        let status = forge == .github ? githubStatus : giteaStatus
        do {
            let refs: [RepoRef]
            switch forge {
            case .github:
                refs = try await GitHubClient(credentials: GitHubCredentials(token: resolved, scope: "")).listRepositories()
            case .gitea:
                let instance = giteaInstance.stringValue.trimmingCharacters(in: .whitespaces)
                guard !instance.isEmpty else { return false }
                refs = try await GiteaClient(credentials: GiteaCredentials(token: resolved, scope: "", instance: instance)).listRepositories()
            }
            let combo = forge == .github ? githubRepo : giteaScope
            let current = combo.stringValue
            combo.removeAllItems()
            combo.addItems(withObjectValues: refs.prefix(300).map(\.fullName))
            combo.stringValue = current
            if token != nil {
                status.stringValue = "Connected ✓ — \(refs.count) repositories visible. Pick one below."
                status.textColor = .systemGreen
            }
            return true
        } catch {
            if token != nil {
                status.stringValue = "That token didn't work — \(error.localizedDescription)"
                status.textColor = .systemRed
            }
            return false
        }
    }

    /// After a token is stored, verify the runner-management permission for
    /// the live scope. For org scopes this surfaces the PAT-permission error
    /// with its remediation instead of the generic "Connected ✓". GitHub
    /// only: Gitea doesn't use OAuth runner-management tokens.
    private func verifyPermission(scope: String) async {
        let report = await OrgPermissionProbe.verify(github: GitHubClient(credentials: GitHubCredentials(token: "", scope: scope)), scope: scope)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.githubStatus.stringValue = report.message
            self.githubStatus.textColor = report.ok ? .systemGreen : .systemRed
            self.githubConnect.title = report.ok ? "Replace" : "Connect"
        }
    }

    // MARK: Config writes

    @objc private func githubRepoCommitted() { commitGitHubRepo() }

    private func commitGitHubRepo() {
        let value = githubRepo.stringValue.trimmingCharacters(in: .whitespaces)
        guard githubTokenStored, !value.isEmpty, value != lastWrittenRepo else { return }
        do {
            try GeneralConfigEditor.apply(.repo(value), to: configURL)
            lastWrittenRepo = value
            githubStatus.stringValue = "Now serving \(value) ✓"
            githubStatus.textColor = .systemGreen
            githubConnected = githubTokenStored
            onChanged?()
        } catch {
            githubStatus.stringValue = "Not saved — \(error.localizedDescription)"
            githubStatus.textColor = .systemRed
        }
    }

    @objc private func giteaScopeCommitted() { commitGitea() }

    @objc private func giteaToggled() {
        giteaBody.isHidden = giteaToggle.state != .on
        if giteaToggle.state == .off, lastWrittenGitea != nil {
            do {
                try GeneralConfigEditor.apply(.gitea(nil), to: configURL)
                lastWrittenGitea = nil
                giteaConnected = false
                onChanged?()
            } catch {
                giteaStatus.stringValue = "Not saved — \(error.localizedDescription)"
                giteaStatus.textColor = .systemRed
            }
        }
    }

    /// The `gitea:` section needs both a server and a scope; write it once
    /// both are known.
    private func commitGitea() {
        let instance = giteaInstance.stringValue.trimmingCharacters(in: .whitespaces)
        let scope = giteaScope.stringValue.trimmingCharacters(in: .whitespaces)
        guard giteaTokenStored, !instance.isEmpty, !scope.isEmpty else { return }
        let section = GeneralConfigEditor.Snapshot.Gitea(instance: instance, scope: scope)
        guard section != lastWrittenGitea else { return }
        do {
            try GeneralConfigEditor.apply(.gitea(section), to: configURL)
            lastWrittenGitea = section
            giteaConnected = giteaTokenStored
            giteaStatus.stringValue = "Now serving \(scope) on Gitea ✓"
            giteaStatus.textColor = .systemGreen
            onChanged?()
        } catch {
            giteaStatus.stringValue = "Not saved — \(error.localizedDescription)"
            giteaStatus.textColor = .systemRed
        }
    }

    // MARK: Delegates

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSControl else { return }
        if field === githubRepo { commitGitHubRepo() }
        if field === giteaInstance || field === giteaScope { commitGitea() }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox else { return }
        // The selection is applied to stringValue after this callback.
        DispatchQueue.main.async { [weak self] in
            if combo === self?.githubRepo { self?.commitGitHubRepo() }
            if combo === self?.giteaScope { self?.commitGitea() }
        }
    }

    // MARK: Test hooks

    var repoFieldsEnabledForTesting: (github: Bool, gitea: Bool) { (githubRepo.isEnabled, giteaScope.isEnabled) }

    func markTokensStoredForTesting(github: Bool, gitea: Bool) {
        githubTokenStored = github
        giteaTokenStored = gitea
        githubConnected = github && !lastWrittenRepo.isEmpty
        giteaConnected = gitea && lastWrittenGitea != nil
    }

    func enterGitHubRepoForTesting(_ value: String) {
        githubRepo.stringValue = value
        commitGitHubRepo()
    }

    func enterGiteaForTesting(instance: String, scope: String) {
        giteaToggle.state = .on
        giteaBody.isHidden = false
        giteaInstance.stringValue = instance
        giteaScope.stringValue = scope
        commitGitea()
    }
}

private extension NSSecureTextField {
    func becomeFirstResponderSelecting() {
        window?.makeFirstResponder(self)
    }
}
