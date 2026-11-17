import KinhinKit
import SwiftUI

/// The Add/Edit webhook sheet. Its problems render inside it with the entered values intact.
struct AlertWebhookSheet: View {
    @Bindable var model: AlertsModel

    var body: some View {
        let editing = model.draft?.original != nil
        SheetScaffold(
            title: editing ? "Edit webhook" : "Add webhook", width: 480,
            content: {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    labeled("Name") {
                        TextField("Name", text: field(\.name))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("alerts-sheet-name")
                    }
                    labeled("URL") {
                        SecureField(
                            "URL", text: field(\.url),
                            prompt: Text(editing ? "Leave empty to keep the stored URL" : "https://hooks.example.com/…")
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("alerts-sheet-url")
                    }
                    labeled("Format") {
                        Picker("Format", selection: field(\.format)) {
                            ForEach(KinhinConfig.AlertsConfig.Format.allCases, id: \.self) {
                                Text(verbatim: $0.rawValue).tag($0)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    labeled("Token") {
                        SecureField(
                            "Token", text: field(\.token), prompt: Text("Optional bearer token, stored in the Keychain")
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("alerts-sheet-token")
                    }
                    labeled("Minimum severity") {
                        Picker("Minimum severity", selection: field(\.minSeverity)) {
                            Text("Default").tag(AlertSeverity?.none)
                            ForEach(AlertSeverity.allCases, id: \.self) {
                                Text(verbatim: $0.rawValue).tag(AlertSeverity?.some($0))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Toggle("All event types", isOn: field(\.allEvents))
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("alerts-sheet-all-events")
                    if model.draft?.allEvents == false {
                        HStack(spacing: Spacing.lg) {
                            ForEach(AlertsModel.selectableKinds, id: \.self) { kind in
                                Toggle(
                                    isOn: Binding(
                                        get: { model.draft?.events.contains(kind) ?? false },
                                        set: { on in
                                            if on {
                                                model.draft?.events.insert(kind)
                                            } else {
                                                model.draft?.events.remove(kind)
                                            }
                                        })
                                ) {
                                    Text(verbatim: kind.rawValue)
                                }
                                .toggleStyle(.checkbox)
                                .accessibilityIdentifier("alerts-sheet-event-\(kind.rawValue)")
                            }
                        }
                    }
                    if !model.draftProblem.isEmpty {
                        StatusText(verbatim: model.draftProblem, style: .error).textSelection(.enabled)
                    }
                }
            },
            footer: {
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelDraft() }.keyboardShortcut(.cancelAction)
                    Button("Save") { Task { await model.saveDraft() } }
                        .disabled(model.isSaving)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("alerts-sheet-save")
                }
            })
    }

    /// A caption over its control, as the design lays out the sheet's fields.
    private func labeled(_ title: LocalizedStringKey, @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).typeStyle(.caption).fontWeight(.medium).foregroundStyle(.secondary)
            control()
        }
    }

    private func field<T>(_ path: WritableKeyPath<AlertsModel.Draft, T>) -> Binding<T> {
        Binding(
            get: { model.draft?[keyPath: path] ?? AlertsModel.Draft()[keyPath: path] },
            set: { model.draft?[keyPath: path] = $0 })
    }
}
