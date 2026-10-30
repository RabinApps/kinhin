import E2ESupport
import Foundation
import Testing

/// Opt-in OpenTelemetry (issue #64), against a real `kinhin daemon`. Quick tier: the forge is unreachable on purpose (as
/// in `SecurityTests`), because the fleet gauges and the poll spans exist whether or not a job ever runs, so no Docker is
/// needed. OTLP goes to `OTLPCollectorStub`, a local stand-in collector; nothing leaves the Mac.
@Suite("Telemetry", .serialized, .tags(.cli), .enabled(if: E2E.enabled))
struct TelemetryTests {
    private static let account = """
        version: 1
        accounts:
          - name: gitea
            forge: gitea
            scope: acme/widgets
            instance: http://127.0.0.1:9

        """

    /// Fleet gauges the daemon must publish (Prometheus renders `kinhin.workers` as `kinhin_workers`).
    private static let fleetGauges = ["kinhin_workers", "kinhin_queue_depth", "kinhin_fleet_active"]

    private func withSandbox<T>(_ body: (Sandbox) async throws -> T) async throws -> T {
        let sandbox = try Sandbox()
        defer { sandbox.dispose() }
        sandbox.setToken("unreachable-forge-token", account: "gitea")
        return try await body(sandbox)
    }

    private static func scrape(_ port: Int) async -> Http.Response? {
        try? await Http.request("GET", "http://127.0.0.1:\(port)/metrics", timeout: 5)
    }

    @Test("prometheus_listen serves /metrics with kinhin_ fleet gauges")
    func prometheusEndpoint() async throws {
        try await withSandbox { sandbox in
            let port = try E2E.freePort()
            try sandbox.writeConfig(
                Self.account + """
                    telemetry:
                      enabled: true
                      signals: [metrics]
                      prometheus_listen: 127.0.0.1:\(port)

                    """)
            let validated = try await sandbox.kinhin(["config", "validate"])
            #expect(validated.ok, "telemetry: must validate: \(validated.output)")
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }

            let body = try await eventually("/metrics to answer with kinhin_ gauges", timeout: 60, interval: 1) {
                guard let response = await Self.scrape(port), response.ok,
                    Self.fleetGauges.contains(where: { response.text.contains($0) })
                else { return nil as String? }
                return response.text
            }
            #expect(
                body.contains("# TYPE kinhin_"), "Prometheus text format with kinhin_ metrics:\n\(body.prefix(600))")
            for gauge in Self.fleetGauges {
                #expect(body.contains(gauge), "\(gauge) is missing from /metrics:\n\(body.prefix(1200))")
            }
            let other = try await Http.request("POST", "http://127.0.0.1:\(port)/metrics", timeout: 5)
            #expect(!other.ok, "only GET /metrics is served: HTTP \(other.status)")
            #expect(!sandbox.log().contains("unreachable-forge-token"), "the token never reaches the log")
        }
    }

    @Test("the daemon pushes OTLP/HTTP metrics and logs to the collector within the export interval")
    func otlpPush() async throws {
        let collector = try await OTLPCollectorStub()
        defer { collector.stop() }
        try await withSandbox { sandbox in
            try sandbox.writeConfig(
                Self.account + """
                    telemetry:
                      enabled: true
                      endpoint: \(collector.endpoint)
                      protocol: http/protobuf
                      export_interval: 1
                      signals: [metrics, logs]
                      resource_attributes:
                        deployment.environment: e2e

                    """)
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }

            // The interval is 1s; allow for the daemon's start-up and the trace batch delay, not for the interval itself.
            let metrics = try await eventually("OTLP metrics to reach the collector", timeout: 45, interval: 1) {
                let posts = await collector.requests(to: "/v1/metrics")
                return posts.isEmpty ? nil : posts
            }
            #expect(metrics.allSatisfy { $0.contentType.hasPrefix("application/x-protobuf") }, "\(metrics)")
            #expect(metrics.contains { $0.mentionsKinhin && $0.bytes > 0 }, "a metrics export names kinhin.* metrics")

            // The daemon's own log lines (start-up) are exported as OTLP log records.
            let logs = try await eventually("OTLP logs to reach the collector", timeout: 45, interval: 1) {
                let posts = await collector.requests(to: "/v1/logs")
                return posts.isEmpty ? nil : posts
            }
            #expect(logs.contains { $0.bytes > 0 }, "\(logs)")

            // Pushing is periodic, not a one-off: a second metrics export follows.
            let count = metrics.count
            _ = try await eventually("a second metrics export", timeout: 15, interval: 1) {
                await collector.requests(to: "/v1/metrics").count > count ? true : nil as Bool?
            }
            // Traces are per instance job; with no job and `traces` not selected, none are pushed.
            #expect(await collector.requests(to: "/v1/traces").isEmpty, "traces were not in signals:")
        }
    }

    @Test("OTEL_EXPORTER_OTLP_ENDPOINT overrides the config's endpoint")
    func environmentOverridesConfig() async throws {
        let collector = try await OTLPCollectorStub()
        defer { collector.stop() }
        try await withSandbox { sandbox in
            let dead = try E2E.freePort()
            try sandbox.writeConfig(
                Self.account + """
                    telemetry:
                      enabled: true
                      endpoint: http://127.0.0.1:\(dead)
                      export_interval: 1
                      signals: [metrics]

                    """)
            sandbox.setEnvironment("OTEL_EXPORTER_OTLP_ENDPOINT", collector.endpoint)
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            _ = try await eventually("OTLP metrics at the env-var endpoint", timeout: 45, interval: 1) {
                await collector.requests(to: "/v1/metrics").isEmpty ? nil as Bool? : true
            }
        }
    }

    /// Telemetry off opens no listener and exports nothing. Both shapes of "off" are checked: no `telemetry:` section
    /// at all (the default), and an explicit `enabled: false` that still names a port and a collector.
    @Test("with telemetry off nothing is bound and nothing is exported", arguments: [false, true])
    func disabled(explicit: Bool) async throws {
        let collector = try await OTLPCollectorStub()
        defer { collector.stop() }
        try await withSandbox { sandbox in
            let port = try E2E.freePort()
            let section =
                explicit
                ? """
                telemetry:
                  enabled: false
                  endpoint: \(collector.endpoint)
                  export_interval: 1
                  signals: [metrics, traces, logs]
                  prometheus_listen: 127.0.0.1:\(port)

                """ : ""
            try sandbox.writeConfig(Self.account + section)
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }

            // Long enough for several 1s export intervals and a trace batch (5s by default) to have happened if enabled.
            try await Task.sleep(for: .seconds(12))
            #expect(!E2E.isListening(port: port), "the Prometheus port must not be bound with telemetry off")
            let posts = await collector.requests()
            #expect(posts.isEmpty, "the collector must receive nothing with telemetry off: \(posts)")
            #expect(daemon.isRunning, "the daemon is fine without telemetry")
        }
    }

    @Test("a bad telemetry: value is a config error (exit 3) that names the key")
    func badConfig() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig(Self.account + "telemetry:\n  enabled: true\n  protocol: carrier-pigeon\n")
            let bad = try await sandbox.kinhin(["config", "validate"])
            #expect(bad.status == 3, "exit \(bad.status): \(bad.output)")
            #expect(bad.output.contains("telemetry.protocol"), "\(bad.output)")
        }
    }
}
