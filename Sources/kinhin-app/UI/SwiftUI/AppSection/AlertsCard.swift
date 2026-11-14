import KinhinKit
import SwiftUI

/// Advanced → App → Alerts: the switch and the list of alert webhooks, each with the event types it receives.
/// State and actions live in `AlertsModel`.
struct AlertsCard: View {
    @Bindable var model: AlertsModel

    var body: some View {
        FormCard(
            title: "Alerts",
            subtitle:
                "Send a message to your own webhooks (Slack, Discord, ntfy or any JSON endpoint) when the fleet raises a problem and when it clears, even with this app closed. Off by default."
        ) {
            Toggle(
                "Send alerts",
                isOn: Binding(
                    get: { model.configEnabled ?? false },
                    set: { on in Task { await model.setEnabled(on) } })
            )
            .disabled(model.configEnabled == nil)
            .accessibilityIdentifier("alerts-toggle")

            if model.rows.isEmpty {
                HintText("No webhooks yet. Add one to start receiving alerts.")
            }
            ForEach(model.rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: row.name).font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                        Button("Test") { Task { await model.test(row.name) } }
                            .disabled(model.testing != nil)
                            .accessibilityIdentifier("alerts-test-\(row.name)")
                        Button("Edit") { model.beginEdit(row.name) }
                            .accessibilityIdentifier("alerts-edit-\(row.name)")
                        Button("Remove") { Task { await model.remove(row.name) } }
                            .accessibilityIdentifier("alerts-remove-\(row.name)")
                    }
                    HintText(verbatim: model.summary(of: row)).textSelection(.enabled)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("alerts-row-\(row.name)")
            }
            HStack {
                Button("Add webhook") { model.beginAdd() }
                    .disabled(model.configEnabled == nil)
                    .accessibilityIdentifier("alerts-add")
                Button("Refresh") { model.reload() }
            }
            if !model.result.text.isEmpty {
                StatusText(verbatim: model.result.text, style: model.result.style)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("alerts-result")
            }
            HintText(
                "Webhook URLs are kept in config.yaml and shown here without their path. Tokens go in the Keychain, never in the file."
            )
        }
        .sheet(
            isPresented: Binding(
                get: { model.draft != nil }, set: { if !$0 { model.cancelDraft() } })
        ) {
            AlertWebhookSheet(model: model)
        }
    }
}

/// The Add/Edit webhook sheet. Its problems render inside it with the entered values intact.
struct AlertWebhookSheet: View {
    @Bindable var model: AlertsModel

    var body: some View {
        let editing = model.draft?.original != nil
        VStack(alignment: .leading, spacing: 10) {
            Text(editing ? "Edit webhook" : "Add webhook").font(.headline)
            TextField("Name", text: field(\.name))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("alerts-sheet-name")
            SecureField(
                "URL", text: field(\.url),
                prompt: Text(editing ? "Leave empty to keep the stored URL" : "https://hooks.example.com/…")
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("alerts-sheet-url")
            Picker("Format", selection: field(\.format)) {
                ForEach(KinhinConfig.AlertsConfig.Format.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
            }
            SecureField("Token", text: field(\.token), prompt: Text("Optional bearer token, stored in the Keychain"))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("alerts-sheet-token")
            Picker("Minimum severity", selection: field(\.minSeverity)) {
                Text("Default").tag(AlertSeverity?.none)
                ForEach(AlertSeverity.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag(AlertSeverity?.some($0)) }
            }
            Toggle("All event types", isOn: field(\.allEvents))
                .accessibilityIdentifier("alerts-sheet-all-events")
            if model.draft?.allEvents == false {
                ForEach(AlertsModel.selectableKinds, id: \.self) { kind in
                    Toggle(
                        kind.rawValue,
                        isOn: Binding(
                            get: { model.draft?.events.contains(kind) ?? false },
                            set: { on in
                                if on { model.draft?.events.insert(kind) } else { model.draft?.events.remove(kind) }
                            })
                    )
                    .font(.system(size: 11))
                    .accessibilityIdentifier("alerts-sheet-event-\(kind.rawValue)")
                }
            }
            if !model.draftProblem.isEmpty {
                StatusText(verbatim: model.draftProblem, style: .error).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelDraft() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await model.saveDraft() } }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("alerts-sheet-save")
            }
        }
        .padding(16)
        .frame(width: 420, alignment: .leading)
    }

    private func field<T>(_ path: WritableKeyPath<AlertsModel.Draft, T>) -> Binding<T> {
        Binding(
            get: { model.draft?[keyPath: path] ?? AlertsModel.Draft()[keyPath: path] },
            set: { model.draft?[keyPath: path] = $0 })
    }
}
