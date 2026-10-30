import KinhinKit
import SwiftUI

/// Advanced → App → Telemetry: the OpenTelemetry export switch, where each signal goes, the Prometheus address and
/// the last export problem. State and actions live in `TelemetryModel`.
struct TelemetryCard: View {
    let model: TelemetryModel

    var body: some View {
        FormCard(
            title: "Telemetry",
            subtitle:
                "Send metrics, traces and logs about the fleet to your own OpenTelemetry collector, and optionally serve a local Prometheus endpoint. Off by default."
        ) {
            Toggle(
                "Send telemetry",
                isOn: Binding(
                    get: { model.configEnabled ?? false },
                    set: { on in Task { await model.setEnabled(on) } })
            )
            .disabled(model.configEnabled == nil || model.applying)
            .accessibilityIdentifier("telemetry-toggle")

            StatusText(verbatim: model.headline.text, style: model.headline.style)
                .accessibilityIdentifier("telemetry-status")
            if let owner = model.ownerLine { HintText(verbatim: owner) }
            ForEach(model.destinations, id: \.signal) { row in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: row.signal).font(.system(size: 11, weight: .semibold))
                    Text(verbatim: row.endpoint).font(.system(size: 11)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if let url = model.prometheusURL {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Prometheus").font(.system(size: 11, weight: .semibold))
                    Text(verbatim: url).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if let problem = model.problem {
                StatusText(verbatim: problem.text, style: problem.style)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("telemetry-problem")
            }

            HStack {
                TextField(
                    "Prometheus address", text: Binding(get: { model.listenDraft }, set: { model.listenDraft = $0 }),
                    prompt: Text(verbatim: "127.0.0.1:9464")
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.applyListen() } }
                .accessibilityIdentifier("telemetry-prometheus-address")
                Button("Save") { Task { await model.applyListen() } }
                    .disabled(model.configEnabled == nil || model.applying)
                Button("Refresh") { model.reload() }
            }
            HintText(
                "A port alone stays on this Mac. Leave it empty for no Prometheus endpoint. It needs the metrics signal."
            )
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
