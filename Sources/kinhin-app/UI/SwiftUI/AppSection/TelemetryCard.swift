import KinhinKit
import SwiftUI

/// Settings → Telemetry: the OpenTelemetry export switch, who exports, where each signal goes, the Prometheus address
/// and the last export problem. State and actions live in `TelemetryModel`.
struct TelemetryCard: View {
    let model: TelemetryModel

    var body: some View {
        Card(
            title: "Telemetry", subtitle: "Send metrics and traces to your own collector", layout: .fill
        ) {
            VStack(spacing: Spacing.sm) {
                InsetRow(
                    content: {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("Send telemetry").typeStyle(.body).fontWeight(.medium)
                            StatusText(verbatim: model.headline.text, style: model.headline.style)
                                .accessibilityIdentifier("telemetry-status")
                        }
                    },
                    trailing: {
                        Toggle(
                            "Send telemetry",
                            isOn: Binding(
                                get: { model.configEnabled ?? false },
                                set: { on in Task { await model.setEnabled(on) } })
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(model.configEnabled == nil || model.applying)
                        .accessibilityIdentifier("telemetry-toggle")
                    })
                if let owner = model.ownerLine {
                    InsetRow(content: { Text(verbatim: owner).typeStyle(.body).fontWeight(.medium) })
                }
                ForEach(model.destinations, id: \.signal) { row in
                    InsetRow(
                        content: { Text(verbatim: row.signal).typeStyle(.body).fontWeight(.medium) },
                        trailing: {
                            Text(verbatim: row.endpoint).typeStyle(.body).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        })
                }
                if let url = model.prometheusURL {
                    InsetRow(
                        content: { Text("Prometheus URL").typeStyle(.body).fontWeight(.medium) },
                        trailing: {
                            Text(verbatim: url).typeStyle(.body).foregroundStyle(.secondary).textSelection(.enabled)
                        })
                }
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Prometheus address").typeStyle(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                HStack(spacing: Spacing.sm) {
                    TextField(
                        "Prometheus address",
                        text: Binding(get: { model.listenDraft }, set: { model.listenDraft = $0 }),
                        prompt: Text(verbatim: "127.0.0.1:9464")
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .onSubmit { Task { await model.applyListen() } }
                    .accessibilityIdentifier("telemetry-prometheus-address")
                    Button("Save") { Task { await model.applyListen() } }
                        .controlSize(.small)
                        .disabled(model.configEnabled == nil || model.applying)
                    Button("Refresh") { model.reload() }
                        .controlSize(.small)
                }
            }
            HintText(
                "Enter just a port number to serve it on this Mac only (127.0.0.1). Leave it empty for no Prometheus endpoint. It needs the metrics signal."
            )
            if let problem = model.problem {
                StatusText(verbatim: problem.text, style: problem.style)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("telemetry-problem")
            }
            if !model.result.text.isEmpty {
                StatusText(verbatim: model.result.text, style: model.result.style)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("telemetry-result")
            }
            HintText(
                "The collector address, signals and the rest are set in config.yaml. Put collector credentials in the OTEL_EXPORTER_OTLP_HEADERS environment variable, never in the file."
            )
        }
    }
}
