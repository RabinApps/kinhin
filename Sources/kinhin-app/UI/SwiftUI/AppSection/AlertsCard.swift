import KinhinKit
import SwiftUI

/// Settings → Alerts: the switch and the list of alert webhooks, each with the event types it receives.
/// State and actions live in `AlertsModel`.
struct AlertsCard: View {
    @Bindable var model: AlertsModel

    var body: some View {
        Card(title: "Alerts", subtitle: "Webhooks for failures and healing events", layout: .fill) {
            VStack(spacing: Spacing.sm) {
                InsetRow(
                    content: { Text("Send alerts").typeStyle(.body).fontWeight(.medium) },
                    trailing: {
                        Toggle(
                            "Send alerts",
                            isOn: Binding(
                                get: { model.configEnabled ?? false },
                                set: { on in Task { await model.setEnabled(on) } })
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(model.configEnabled == nil || model.isSaving)
                        .accessibilityIdentifier("alerts-toggle")
                    })
                ForEach(model.rows) { row in
                    InsetRow(
                        content: { RowLabel(verbatim: row.name, detail: model.summary(of: row)) },
                        trailing: {
                            HStack(spacing: Spacing.sm) {
                                Button("Test") { Task { await model.test(row.name) } }
                                    .disabled(model.testing != nil)
                                    .accessibilityIdentifier("alerts-test-\(row.name)")
                                Button("Edit") { model.beginEdit(row.name) }
                                    .disabled(model.isSaving)
                                    .accessibilityIdentifier("alerts-edit-\(row.name)")
                                Button("Remove") { Task { await model.remove(row.name) } }
                                    .disabled(model.isSaving)
                                    .accessibilityIdentifier("alerts-remove-\(row.name)")
                            }
                            .controlSize(.small)
                        }
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("alerts-row-\(row.name)")
                }
            }
            if model.rows.isEmpty {
                HintText("No webhooks yet. Add one to start receiving alerts.")
            }
            HStack(spacing: Spacing.sm) {
                Button("Add webhook…") { model.beginAdd() }
                    .disabled(model.configEnabled == nil || model.isSaving)
                    .accessibilityIdentifier("alerts-add")
                Button("Refresh") { model.reload() }
            }
            .controlSize(.small)
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
