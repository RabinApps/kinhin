import AppKit
import KinhinKit

/// Pure, unit-testable content for one provider's card in the token settings
/// form. No AppKit here — the window renders exactly what this computes.
struct TokenSettingsRow: Equatable {
    let forge: ForgeID
    let title: String
    /// Status line: stored state (with masked token prefix) plus the scope /
    /// instance the token is used against. Contains no secret beyond the
    /// 4-character prefix (the same shape `kinhin auth status` prints).
    let status: String
    let placeholder: String
    let buttonTitle: String
    /// False when the provider has no config section yet (Gitea without a
    /// `gitea:` block) — a token can still be stored, it just isn't in use.
    let configured: Bool

    static func make(forge: ForgeID, token: String?, repo: String?, gitea: kinhinConfig.GiteaForgeConfig?)
        -> TokenSettingsRow
    {
        let masked = token.map { String($0.prefix(4)) + "…" } ?? "—"
        switch forge {
        case .github:
            let scope = (repo?.isEmpty == false) ? repo! : "your repo (set it in config.yaml)"
            return TokenSettingsRow(
                forge: forge,
                title: "GitHub",
                status: token != nil
                    ? "Stored in Keychain (\(masked)) · scope: \(scope) — a new token takes effect immediately."
                    : "Not stored — a PAT with repo scope is required (scope: \(scope)).",
                placeholder: "ghp_…",
                buttonTitle: token != nil ? "Replace…" : "Save…",
                configured: true
            )
        case .gitea:
            if let gitea {
                return TokenSettingsRow(
                    forge: forge,
                    title: "Gitea",
                    status: token != nil
                        ? "Stored in Keychain (\(masked)) · scope: \(gitea.scope) @ \(gitea.instance) — a new token takes effect immediately."
                        : "Not stored — a token with runner-management rights is required (scope: \(gitea.scope) @ \(gitea.instance)).",
                    placeholder: "gitea token…",
                    buttonTitle: token != nil ? "Replace…" : "Save…",
                    configured: true
                )
            }
            return TokenSettingsRow(
                forge: forge,
                title: "Gitea",
                status: token != nil
                    ? "Stored in Keychain (\(masked)) — no gitea: section in config.yaml yet, so it is not in use."
                    : "Not in use — add a gitea: section to config.yaml; a token saved here is kept ready.",
                placeholder: "gitea token…",
                buttonTitle: token != nil ? "Replace…" : "Save…",
                configured: false
            )
        }
    }
}

/// The token settings form: one card per provider (GitHub, Gitea) with the
/// stored state, a secure input, and Save/Replace + Check buttons. Saving
/// goes through the AppDelegate-injected `onSaved` callback, which persists
/// to the Keychain and hands the new token to the engine or daemon so a
/// running fleet picks it up without a restart. Checking validates the
/// stored (or just-typed) token against the forge and shows the verdict
/// inline on the card.
@MainActor
final class TokenSettingsWindowController: NSWindowController {
    /// Persist + live-swap callback (injected; throws on Keychain/RPC failure).
    var onSaved: ((ForgeID, String) async throws -> Void)?
    /// Provider whose input gets keyboard focus when the window opens
    /// (the setup checklist's Gitea rows open the form pre-focused there).
    var initialFocus: ForgeID = .github

    private let statusLabel = NSTextField(labelWithString: "")
    private let rowsStack = NSStackView()
    private var inputs: [ForgeID: NSSecureTextField] = [:]
    private var results: [ForgeID: NSTextField] = [:]

    convenience init() {
        self.init(embeddedIn: nil)
    }

    /// Embedded in the main window's Tokens tab: `container` receives the
    /// full form (header + one card per provider). Nil container → the
    /// standalone-window form, unchanged.
    convenience init(embeddedIn container: NSView?) {
        let size = NSSize(width: 560, height: 396)
        let standalone = container == nil
        let contentContainer = container ?? NSView(frame: NSRect(origin: .zero, size: size))
        if standalone {
            let window = NSWindow(
                contentRect: contentContainer.frame,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "kinhin Tokens"
            window.titlebarAppearsTransparent = true
            window.appearance = nil  // follow the system (light & dark)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = contentContainer
            window.center()
            self.init(window: window)
        } else {
            self.init(window: nil)
        }
        buildUI(in: contentContainer)
        reload()
    }

    // MARK: UI construction

    private func buildUI(in container: NSView) {
        container.wantsLayer = true

        let title = NSTextField(labelWithString: "🔑  Access Tokens")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        let headerStack = NSStackView(views: [title, statusLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerStack)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 12
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rowsStack)

        let hint = NSTextField(
            wrappingLabelWithString:
                "Tokens live in your login Keychain — never in a file. A running fleet (app or daemon) picks up the new token without a restart."
        )
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hint)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            headerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),

            rowsStack.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 14),
            rowsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            rowsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            hint.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            hint.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
    }

    // MARK: Rendering

    /// Re-reads Keychain + config state and re-renders the cards (clearing
    /// stale check results with them).
    func reload() {
        inputs.removeAll()
        results.removeAll()
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let cfg = try? ConfigLoader.load()
        for forge in ForgeID.allCases {
            let row = TokenSettingsRow.make(
                forge: forge,
                token: KeychainTokenStore.load(forge: forge),
                repo: cfg?.repo,
                gitea: cfg?.gitea
            )
            rowsStack.addArrangedSubview(makeCard(for: row))
        }
    }

    private func makeCard(for row: TokenSettingsRow) -> NSView {
        let card = LayerStyleView(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.styleLayer = { layer in
            layer.cornerRadius = 10
            layer.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer.borderWidth = 1
            layer.borderColor = NSColor.separatorColor.cgColor
        }

        let nameLabel = NSTextField(labelWithString: row.title)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let status = NSTextField(wrappingLabelWithString: row.status)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2

        // Inline verdict of the last Check (hidden until one runs).
        let result = NSTextField(wrappingLabelWithString: "")
        result.font = .systemFont(ofSize: 11)
        result.textColor = .secondaryLabelColor
        result.maximumNumberOfLines = 2
        result.isHidden = true
        result.translatesAutoresizingMaskIntoConstraints = false
        results[row.forge] = result

        let input = NSSecureTextField(frame: .zero)
        input.placeholderString = row.placeholder
        input.font = .systemFont(ofSize: 12)
        input.translatesAutoresizingMaskIntoConstraints = false
        input.setAccessibilityLabel("\(row.title) access token")
        inputs[row.forge] = input

        let check = NSButton(title: "Check", target: self, action: #selector(checkClicked(_:)))
        check.bezelStyle = .rounded
        check.controlSize = .small
        check.translatesAutoresizingMaskIntoConstraints = false
        check.setAccessibilityLabel("Check the stored \(row.title) token")
        // Dispatch off the forge id, mirroring the checklist's action-id pattern.
        check.identifier = NSUserInterfaceItemIdentifier("check_\(row.forge.rawValue)")

        let replace = NSButton(title: row.buttonTitle, target: self, action: #selector(replaceClicked(_:)))
        replace.bezelStyle = .rounded
        replace.controlSize = .small
        replace.translatesAutoresizingMaskIntoConstraints = false
        replace.identifier = NSUserInterfaceItemIdentifier("replace_\(row.forge.rawValue)")

        let column = NSStackView(views: [nameLabel, status, result])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false

        let fieldRow = NSStackView(views: [input, check, replace])
        fieldRow.orientation = .horizontal
        fieldRow.spacing = 8
        fieldRow.translatesAutoresizingMaskIntoConstraints = false
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)
        check.setContentCompressionResistancePriority(.required, for: .horizontal)
        replace.setContentCompressionResistancePriority(.required, for: .horizontal)

        card.addSubview(column)
        card.addSubview(fieldRow)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 128),
            card.widthAnchor.constraint(equalToConstant: 520),

            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -14),

            fieldRow.topAnchor.constraint(greaterThanOrEqualTo: column.bottomAnchor, constant: 8),
            fieldRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            fieldRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            fieldRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            input.heightAnchor.constraint(equalToConstant: 22),
        ])
        return card
    }

    // MARK: Actions

    @objc private func replaceClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, id.hasPrefix("replace_"),
            let forge = ForgeID(rawValue: String(id.dropFirst("replace_".count))),
            let input = inputs[forge]
        else { return }
        let token = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            input.selectText(nil)
            return
        }
        guard let save = onSaved else {
            Log.error("tokens", "no save handler wired for the token settings form")
            return
        }
        sender.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            do {
                try await save(forge, token)
                self.statusLabel.stringValue = "Saved — \(self.providerName(forge)) token updated."
            } catch {
                Log.error("app", "token replacement failed: \(error.localizedDescription)")
                let alert = NSAlert(error: error)
                alert.alertStyle = .critical
                alert.messageText = "Could not save the \(self.providerName(forge)) token"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
            self.reload()
            self.inputs[forge]?.selectText(nil)
        }
    }

    /// Validates the stored token (or the one just typed into the field, so
    /// a bad paste can be caught before saving) against the forge and shows
    /// the verdict inline on the card.
    @objc private func checkClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, id.hasPrefix("check_"),
            let forge = ForgeID(rawValue: String(id.dropFirst("check_".count)))
        else { return }
        let typed = inputs[forge]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let config = try? ConfigLoader.load()

        sender.isEnabled = false
        let originalTitle = sender.title
        sender.title = "Checking…"
        Task { [weak self] in
            guard let self else { return }
            let report = await TokenHealthCheck.check(
                forge: forge,
                config: config,
                // A non-empty field overrides the Keychain for this check.
                keychainToken: { f in
                    (f == forge && !typed.isEmpty) ? typed : KeychainTokenStore.load(forge: f)
                }
            )
            sender.isEnabled = true
            sender.title = originalTitle
            Log.info("tokens", "checked \(forge.rawValue) token: ok=\(report.ok)")
            self.show(report, for: forge)
        }
    }

    private func show(_ report: TokenHealthCheck.Report, for forge: ForgeID) {
        guard let label = results[forge] else { return }
        label.stringValue = "\(report.ok ? "✓" : "✗") \(report.message)"
        label.textColor = report.ok ? NSColor.systemGreen : NSColor.systemRed
        label.isHidden = false
    }

    private func providerName(_ forge: ForgeID) -> String {
        forge == .github ? "GitHub" : "Gitea"
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        reload()
        window?.makeFirstResponder(inputs[initialFocus])
    }
}
