import Foundation
import KinhinKit

/// `kinhin telemetry [status]`: whether the daemon's telemetry pipeline runs, where it sends, and whether exports
/// are failing. Asks the daemon (it owns the exporters); with no daemon it says what the config would start. Never
/// prints header values or URL credentials. Exits 0 when telemetry is off or healthy, 1 when exports are failing or
/// the config enables telemetry but no daemon runs.
enum TelemetryCommand {
    static let usage = "usage: kinhin telemetry [status] [--json] [--quiet]"

    /// The `--json` document.
    struct Document: Codable, Equatable {
        /// False when no daemon answered; `status` then describes only what the config would start.
        var daemon: Bool
        var status: TelemetryStatus
        var message: String?
    }

    static func run(_ args: [String], subcommand: String?) async throws {
        guard subcommand == nil || subcommand == "status" else { fail(usage, exit: .usage) }
        let json = args.contains("--json")
        let quiet = args.contains("--quiet") || args.contains("-q")
        let document = try await self.document()
        if !quiet {
            if json {
                try emitJSON(document, dates: .iso8601)
            } else {
                print(render(document))
            }
        }
        ExitRule.finish(healthy: healthy(document))
    }

    /// The daemon's answer, or the configured state when none runs.
    static func document(
        ask: (() throws -> TelemetryStatus)? = nil, config: KinhinConfig? = nil,
        daemonAlive: () -> Bool = { RPCClient.isDaemonAlive() }
    ) async throws -> Document {
        if daemonAlive() || ask != nil {
            do {
                let status = try (ask ?? { try RPCClient().telemetryStatus() })()
                return Document(daemon: true, status: status, message: nil)
            } catch {
                fail(error.localizedDescription, exit: .runtime)
            }
        }
        let configured = (config ?? loadConfigLeniently()).telemetry
        var status = TelemetryStatus.disabled
        status.enabled = configured.enabled
        status.signals = configured.signals.map(\.rawValue).sorted()
        status.prometheus = configured.prometheusListen
        let message =
            configured.enabled
            ? "telemetry is enabled in the config, but no daemon is running; it starts with the daemon (kinhin daemon install)"
            : "no daemon is running; telemetry is off in the config"
        return Document(daemon: false, status: status, message: message)
    }

    static func healthy(_ document: Document) -> Bool {
        if !document.daemon { return !document.status.enabled }
        return !document.status.enabled || !document.status.hasRecentFailure()
    }

    static func render(_ document: Document, now: Date = Date()) -> String {
        let status = document.status
        var lines: [String] = []
        if let message = document.message { lines.append(message) }
        guard document.daemon else { return lines.joined(separator: "\n") }
        guard status.enabled else {
            return "telemetry is off (telemetry.enabled is false, or OTEL_SDK_DISABLED is set)"
        }
        lines.append("telemetry: on, \(status.otlpProtocol ?? "?"), signals \(status.signals.joined(separator: ", "))")
        for (signal, url) in status.endpoints.sorted(by: { $0.key < $1.key }) { lines.append("  \(signal) -> \(url)") }
        if let prometheus = status.prometheus { lines.append("  prometheus: http://\(prometheus)/metrics") }
        if !status.jobAttributes.isEmpty {
            lines.append("  job dimensions: \(status.jobAttributes.joined(separator: ", "))")
        }
        if status.signals.contains("traces"), let ratio = status.samplingRatio, ratio < 1 {
            lines.append("  trace sampling: " + String(format: "%g", ratio * 100) + "% of jobs")
        }
        if status.persist == true { lines.append("  persist: spans and logs are queued on disk") }
        if let startedAt = status.startedAt { lines.append("  running since \(relative(startedAt, now: now))") }
        if let at = status.lastFailureAt, let message = status.lastFailure {
            let prefix = status.hasRecentFailure(now: now) ? "export problem" : "last export problem"
            lines.append("  \(prefix) (\(relative(at, now: now)), \(status.exportFailures) so far): \(message)")
        } else {
            lines.append("  no export problems reported")
        }
        return lines.joined(separator: "\n")
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 90 { return "\(seconds)s ago" }
        if seconds < 5400 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}
