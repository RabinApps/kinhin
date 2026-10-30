import Foundation

/// Counts forge API requests for `kinhin.forge.requests`, from the shared HTTP paths. The forge
/// clients are built by factories far from the engine, so this reads the process's telemetry
/// handle (the no-op unless a `TelemetryService` started). Attributes: forge and status class only.
enum ForgeRequestMetrics {
    static func record(forge: ForgeID, status: Int?) {
        let telemetry = TelemetryService.shared.telemetry
        guard telemetry.isEnabled else { return }
        telemetry.add(
            .forgeRequests, 1, [Metric.Attr.forge: forge.rawValue, Metric.Attr.statusClass: statusClass(status)])
    }

    /// `2xx`…`5xx`, or `error` when no response arrived.
    static func statusClass(_ status: Int?) -> String {
        guard let status, (100...599).contains(status) else { return "error" }
        return "\(status / 100)xx"
    }
}
