import Foundation
import KinhinKit
import Observation

/// State and actions behind the Alerts card (Advanced → App): the master switch and the list of alert webhooks,
/// each with the event types it receives. Edits go through `AlertsConfigEditor` (only `alerts.enabled` and the
/// `webhooks:` list change, validated by `ConfigLoader`), then `onChanged` pushes the file to the engine or daemon,
/// which restarts alert delivery. The card never shows a webhook URL beyond `scheme://host` (the path is often the
/// secret) and never shows a token: a token typed in the sheet goes straight to the Keychain.
@MainActor
@Observable
final class AlertsModel: ConfigFormModel {
    /// One configured webhook as the card lists it.
    struct Row: Equatable, Identifiable {
        var name: String
        var format: KinhinConfig.AlertsConfig.Format
        /// `scheme://host` only.
        var endpoint: String
        /// The selected event types; nil = all.
        var events: Set<AlertEventKind>?
        var minSeverity: AlertSeverity?
        var keychainName: String?
        var id: String { name }
    }

    /// The sheet's fields for adding or editing a webhook.
    /// True while a config edit is being written; further edits are ignored until it finishes.
    private(set) var isSaving = false

    struct Draft: Equatable {
        /// Identifies this sheet, so a save that finishes after Cancel and a new sheet clears only its own.
        let id = UUID()
        /// The webhook being edited; nil when adding.
        var original: String?
        var name = ""
        /// Empty while editing means "keep the stored URL" (it is never shown).
        var url = ""
        var format = KinhinConfig.AlertsConfig.Format.generic
        /// Entered token; empty keeps whatever the Keychain holds.
        var token = ""
        var minSeverity: AlertSeverity?
        var allEvents = true
        var events: Set<AlertEventKind> = Set(AlertEventKind.selectable)
        var notifyOnResolve: Bool?
    }

    /// The event types a webhook can pick (everything but the synthetic `test`).
    static let selectableKinds = AlertEventKind.selectable

    @ObservationIgnored var configURL: URL = Paths.config
    @ObservationIgnored var onChanged: (() -> Void)?
    /// Sends the test message through one webhook (tests replace this).
    @ObservationIgnored var sendTest: (KinhinConfig.AlertsConfig.Webhook) async throws -> [String] = { webhook in
        try await AlertDelivery.sendTest(
            KinhinConfig.AlertsConfig(enabled: true, webhooks: [webhook]), webhook: webhook.name)
    }
    /// Stores a bearer token in the Keychain under the account name (tests replace this).
    @ObservationIgnored var storeToken: (String, String) throws -> Void = {
        try KeychainTokenStore.saveAlertsToken($0, account: $1)
    }

    private(set) var configEnabled: Bool?
    private(set) var rows: [Row] = []
    /// The Add/Edit sheet is open while this is non-nil.
    var draft: Draft?
    /// What is wrong with the sheet's entries, shown inside the sheet.
    private(set) var draftProblem = ""
    private(set) var result = StatusLine(text: "")
    /// The webhook whose test is in flight.
    private(set) var testing: String?
    @ObservationIgnored private var webhooks: [KinhinConfig.AlertsConfig.Webhook] = []

    // MARK: - Loading

    func reload() {
        do {
            let snapshot = try AlertsConfigEditor.snapshot(in: ConfigStore.text(at: configURL))
            configEnabled = snapshot.enabled
            webhooks = snapshot.webhooks
            rows = snapshot.webhooks.map {
                Row(
                    name: $0.name, format: $0.format,
                    endpoint: URL(string: $0.url).map(AlertDelivery.redactedEndpoint) ?? "?", events: $0.events,
                    minSeverity: $0.minSeverity, keychainName: $0.headersKeychain)
            }
        } catch {
            configEnabled = nil
            webhooks = []
            rows = []
            result = .unreadableConfig(error)
        }
    }

    // MARK: - Editing

    func setEnabled(_ on: Bool) async {
        guard await save(.enabled(on)) else { return }
        result = StatusLine(
            text: on
                ? String(
                    localized: "Alerts turned on in config.yaml.", bundle: .l10n,
                    comment: "Settings → App → Alerts status after the switch is turned on")
                : String(
                    localized: "Alerts turned off in config.yaml.", bundle: .l10n,
                    comment: "Settings → App → Alerts status after the switch is turned off"), style: .ok)
    }

    func remove(_ name: String) async {
        guard await save(.removeWebhook(name)) else { return }
        result = StatusLine(
            text: String(
                localized: "Webhook \(name) removed.", bundle: .l10n,
                comment: "Settings → App → Alerts status; %@ is the webhook's name"), style: .ok)
    }

    /// Sends the test message through one webhook and shows each outcome. Works while alerts are off.
    func test(_ name: String) async {
        guard let webhook = webhooks.first(where: { $0.name == name }) else { return }
        testing = name
        defer { testing = nil }
        do {
            _ = try await sendTest(webhook)
            result = StatusLine(
                text: String(
                    localized: "Test alert sent to \(name).", bundle: .l10n,
                    comment: "Settings → App → Alerts status after a test succeeds; %@ is the webhook's name"),
                style: .ok)
        } catch {
            result = StatusLine(
                text: String(
                    localized: "Test to \(name) failed — \(error.localizedDescription)", bundle: .l10n,
                    comment: "Settings → App → Alerts status; the webhook's name, then the reason"), style: .error)
        }
    }

    // MARK: - The sheet

    func beginAdd() {
        draftProblem = ""
        draft = Draft()
    }

    func beginEdit(_ name: String) {
        guard let webhook = webhooks.first(where: { $0.name == name }) else { return }
        draftProblem = ""
        var next = Draft(original: name)
        next.name = webhook.name
        next.format = webhook.format
        next.minSeverity = webhook.minSeverity
        next.allEvents = webhook.events == nil
        next.events = webhook.events ?? Set(Self.selectableKinds)
        next.notifyOnResolve = webhook.notifyOnResolve
        draft = next
    }

    func cancelDraft() {
        draft = nil
        draftProblem = ""
    }

    /// Validates the sheet through the editor (and the loader behind it), stores a typed token, and closes the sheet.
    /// A refusal stays in the sheet with the entries intact.
    func saveDraft() async {
        guard let draft else { return }
        let existing = webhooks.first { $0.name == draft.original }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        var url = draft.url.trimmingCharacters(in: .whitespaces)
        if url.isEmpty, let existing { url = existing.url }
        let token = draft.token.trimmingCharacters(in: .whitespacesAndNewlines)
        var webhook = KinhinConfig.AlertsConfig.Webhook(
            name: name, url: url, format: draft.format, headersKeychain: existing?.headersKeychain,
            minSeverity: draft.minSeverity, events: draft.allEvents ? nil : draft.events,
            notifyOnResolve: draft.notifyOnResolve)
        if !token.isEmpty { webhook.headersKeychain = webhook.headersKeychain ?? name }
        if !draft.allEvents && draft.events.isEmpty {
            draftProblem = String(
                localized: "Pick at least one event type, or choose all of them.", bundle: .l10n,
                comment: "Alerts sheet problem when no event type is selected")
            return
        }
        guard await save(.saveWebhook(webhook, replacing: draft.original), toSheet: true) else { return }
        if !token.isEmpty, let account = webhook.headersKeychain {
            do {
                try storeToken(token, account)
            } catch {
                result = StatusLine(
                    text: String(
                        localized: "Webhook saved, but the token could not be stored — \(error.localizedDescription)",
                        bundle: .l10n, comment: "Settings → App → Alerts status; %@ is the Keychain error"),
                    style: .warn)
                if self.draft?.id == draft.id { self.draft = nil }
                return
            }
        }
        if self.draft?.id == draft.id { self.draft = nil }
        result = StatusLine(
            text: String(
                localized: "Webhook \(name) saved.", bundle: .l10n,
                comment: "Settings → App → Alerts status; %@ is the webhook's name"), style: .ok)
    }

    /// Writes one field; false (with the reason shown) when the editor refused it and nothing was written.
    private func save(_ field: AlertsConfigEditor.Field, toSheet: Bool = false) async -> Bool {
        // One edit at a time: two overlapping read-validate-write cycles on the file could restore what the first removed.
        guard !isSaving else {
            // A second edit that gets here before the controls disable is refused out loud, not dropped.
            result = StatusLine(
                text: String(
                    localized: "Another change is still being saved — try again in a moment.", bundle: .l10n,
                    comment: "Settings → App → Alerts status when an edit is refused because one is being written"),
                style: .warn)
            return false
        }
        isSaving = true
        defer { isSaving = false }
        let url = configURL
        do {
            _ = try await Task.detached { try AlertsConfigEditor.apply(field, to: url) }.value
            reload()
            onChanged?()
            return true
        } catch {
            if toSheet {
                draftProblem = error.localizedDescription
            } else {
                result = .notSaved(error)
            }
            return false
        }
    }

    // MARK: - What the card says

    func summary(of row: Row) -> String {
        let events: String
        if let kinds = row.events {
            events = kinds.sorted().map(\.rawValue).joined(separator: ", ")
        } else {
            events = String(
                localized: "all events", bundle: .l10n, comment: "Alerts card: a webhook that receives every event type"
            )
        }
        return "\(row.format.rawValue) · \(row.endpoint) · \(events)"
    }
}
