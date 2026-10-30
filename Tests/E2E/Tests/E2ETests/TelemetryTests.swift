import E2ESupport
import Foundation
import Testing

/// Opt-in OpenTelemetry (issue #64), against a real `kinhin daemon`. Quick tier: the forge is unreachable on purpose (as
/// in `SecurityTests`), because the fleet gauges, the forge request counters and the log records exist whether or not a
/// job ever runs, so no Docker is needed. OTLP goes to `OTLPCollectorStub`, a local stand-in collector that records what
/// each export carries; nothing leaves the Mac. The job-driven signals (phase timings, job counters, the job trace) are
/// checked against a real forge and runtime in `TelemetryLifecycleTests`.
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

    /// Gauges published on every reconcile pass whatever the fleet holds (Prometheus renders `kinhin.fleet.active` as
    /// `kinhin_fleet_active`). Series with no value yet (`cicd_worker_count` with no instance) are absent by design.
    private static let alwaysPublished = [
        "kinhin_fleet_desired", "kinhin_fleet_active", "kinhin_fleet_running", "kinhin_fleet_paused",
        "kinhin_pool_capacity", "kinhin_host_disk_free", "process_memory_usage",
    ]

    private static let secret = "e2e-collector-secret-value"

    private func withSandbox<T>(_ body: (Sandbox) async throws -> T) async throws -> T {
        let sandbox = try Sandbox()
        defer { sandbox.dispose() }
        sandbox.setToken("unreachable-forge-token", account: "gitea")
        return try await body(sandbox)
    }

    private static func scrape(_ port: Int, host: String = "127.0.0.1") async -> Http.Response? {
        try? await Http.request("GET", "http://\(host):\(port)/metrics", timeout: 5)
    }

    private static func telemetry(_ lines: String) -> String { account + "telemetry:\n" + lines + "\n" }

    // MARK: - Prometheus

    @Test("prometheus_listen serves /metrics with the always-published kinhin_ gauges")
    func prometheusEndpoint() async throws {
        try await withSandbox { sandbox in
            let port = try E2E.freePort()
            try sandbox.writeConfig(
                Self.telemetry(
                    """
                      enabled: true
                      signals: [metrics]
                      prometheus_listen: 127.0.0.1:\(port)
                    """))
            let validated = try await sandbox.kinhin(["config", "validate"])
            #expect(validated.ok, "telemetry: must validate: \(validated.output)")
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }

            let body = try await eventually("/metrics to carry the fleet gauges", timeout: 60, interval: 1) {
                guard let response = await Self.scrape(port), response.ok,
                    Self.alwaysPublished.allSatisfy({ response.text.contains($0) })
                else { return nil as String? }
                return response.text
            }
            for name in Self.alwaysPublished {
                #expect(body.contains(name), "\(name) is missing from /metrics:\n\(body.prefix(1500))")
            }
            #expect(body.contains("# TYPE kinhin_"), "Prometheus text format:\n\(body.prefix(600))")
            #expect(body.contains("kinhin_pool=\""), "capacity is per pool")

            // The (unreachable) forge's requests are counted by forge and status class, never by URL or error text.
            let counted = try await eventually("the forge request counter", timeout: 60, interval: 2) {
                guard let text = await Self.scrape(port)?.text, text.contains("kinhin_forge_api_requests") else {
                    return nil as String?
                }
                return text
            }
            #expect(counted.contains("kinhin_forge=\"gitea\""), "\(counted.prefix(1500))")
            #expect(
                counted.contains("http_response_status_class=\"error\""), "a refused connection is class `error`")
            #expect(!counted.contains("127.0.0.1:9"), "no URL becomes a label")

            // Only GET /metrics is served, and no token or instance name leaks into the text.
            let post = try await Http.request("POST", "http://127.0.0.1:\(port)/metrics", timeout: 5)
            #expect(!post.ok, "only GET /metrics is served: HTTP \(post.status)")
            let other = try await Http.request("GET", "http://127.0.0.1:\(port)/", timeout: 5)
            #expect(other.status == 404, "only /metrics is served: HTTP \(other.status)")
            #expect(!counted.contains("unreachable-forge-token"), "the token never reaches /metrics")
            #expect(!sandbox.log().contains("unreachable-forge-token"), "the token never reaches the log")
        }
    }

    @Test("a bare prometheus_listen port binds loopback only; 0.0.0.0 is reachable and warns")
    func prometheusBinding() async throws {
        guard let lan = E2E.lanAddress else { throw E2EError.unavailable("no LAN address to probe the bind with") }
        try await withSandbox { sandbox in
            let port = try E2E.freePort()
            try sandbox.writeConfig(
                Self.telemetry("  enabled: true\n  signals: [metrics]\n  prometheus_listen: \(port)"))
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            try await eventually("loopback /metrics", timeout: 60, interval: 1) {
                await Self.scrape(port)?.ok == true ? true : nil as Bool?
            }
            #expect(await Self.scrape(port, host: lan) == nil, "a bare port must not be reachable on \(lan)")
            #expect(!sandbox.log().contains("not loopback"), "loopback is the safe default: no warning")
        }
        try await withSandbox { sandbox in
            let port = try E2E.freePort()
            try sandbox.writeConfig(
                Self.telemetry("  enabled: true\n  signals: [metrics]\n  prometheus_listen: 0.0.0.0:\(port)"))
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            try await eventually("/metrics on the LAN address", timeout: 60, interval: 1) {
                await Self.scrape(port, host: lan)?.ok == true ? true : nil as Bool?
            }
            #expect(sandbox.log().contains("not loopback"), "binding beyond loopback is logged as a warning")
        }
    }

    @Test("a Prometheus port that is already taken leaves telemetry off and the daemon up")
    func prometheusPortInUse() async throws {
        let squatter = try await OTLPCollectorStub()
        defer { squatter.stop() }
        try await withSandbox { sandbox in
            try sandbox.writeConfig(
                Self.telemetry(
                    "  enabled: true\n  signals: [metrics]\n  prometheus_listen: 127.0.0.1:\(squatter.port)"))
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            try await eventually("the bind failure to be logged", timeout: 30, interval: 1) {
                sandbox.log().contains("could not start the Prometheus endpoint") ? true : nil as Bool?
            }
            #expect(sandbox.log().contains("telemetry stays off"))
            #expect(daemon.isRunning, "telemetry trouble must never take the fleet down")
            let status = try await sandbox.kinhin(["status", "--json"], timeout: 15)
            #expect(status.ok, "the daemon still answers: \(status.output)")
        }
    }

    // MARK: - Reload

    @Test("config reload moves, keeps and stops the Prometheus listener without a restart")
    func reloadAppliesInPlace() async throws {
        try await withSandbox { sandbox in
            let first = try E2E.freePort()
            let second = try E2E.freePort()
            func write(_ lines: String) throws { try sandbox.writeConfig(Self.telemetry(lines)) }
            func listener(_ port: Int) -> String {
                "  enabled: true\n  signals: [metrics]\n  prometheus_listen: 127.0.0.1:\(port)"
            }
            try write(listener(first))
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            try await eventually("the first listener", timeout: 60, interval: 1) {
                await Self.scrape(first)?.ok == true ? true : nil as Bool?
            }
            let pid = daemon.processID

            // Unchanged settings: the reload succeeds and the listener keeps answering.
            let same = try await sandbox.kinhin(["config", "reload"], timeout: 60)
            #expect(same.ok, "reload: \(same.output)")
            #expect(await Self.scrape(first)?.ok == true)

            // Moved: the old port is released, the new one serves, and it is the same daemon process.
            try write(listener(second))
            let moved = try await sandbox.kinhin(["config", "reload"], timeout: 60)
            #expect(moved.ok, "reload: \(moved.output)")
            try await eventually("the new listener", timeout: 30, interval: 1) {
                await Self.scrape(second)?.ok == true ? true : nil as Bool?
            }
            try await eventually("the old listener to be released", timeout: 30, interval: 1) {
                E2E.isListening(port: first) ? nil : true as Bool?
            }
            #expect(daemon.processID == pid && daemon.isRunning, "a telemetry reload must not restart the daemon")

            // Off: nothing is bound any more.
            try write("  enabled: false\n  prometheus_listen: 127.0.0.1:\(second)")
            let off = try await sandbox.kinhin(["config", "reload"], timeout: 60)
            #expect(off.ok, "reload: \(off.output)")
            try await eventually("the listener to close", timeout: 30, interval: 1) {
                E2E.isListening(port: second) ? nil : true as Bool?
            }

            // And back on, on the first port again (a released port can be reused at once).
            try write(listener(first))
            #expect(try await sandbox.kinhin(["config", "reload"], timeout: 60).ok)
            try await eventually("the listener to come back", timeout: 30, interval: 1) {
                await Self.scrape(first)?.ok == true ? true : nil as Bool?
            }
        }
    }

    @Test("config reload refuses an invalid config before it reaches the daemon")
    func reloadRejectsInvalidConfig() async throws {
        try await withSandbox { sandbox in
            let port = try E2E.freePort()
            try sandbox.writeConfig(
                Self.telemetry("  enabled: true\n  signals: [metrics]\n  prometheus_listen: 127.0.0.1:\(port)"))
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            try await eventually("the listener", timeout: 60, interval: 1) {
                await Self.scrape(port)?.ok == true ? true : nil as Bool?
            }
            try sandbox.writeConfig(Self.telemetry("  enabled: true\n  protocol: carrier-pigeon"))
            let bad = try await sandbox.kinhin(["config", "reload"], timeout: 60)
            #expect(bad.status == 3, "exit \(bad.status): \(bad.output)")
            #expect(bad.output.contains("telemetry.protocol"), "\(bad.output)")
            #expect(await Self.scrape(port)?.ok == true, "the running daemon keeps its telemetry")
        }
    }

    // MARK: - OTLP

    @Test("OTLP/HTTP: metrics and logs reach the collector with the kinhin resource, then keep coming")
    func otlpPush() async throws {
        let collector = try await OTLPCollectorStub()
        defer { collector.stop() }
        try await withSandbox { sandbox in
            try sandbox.writeConfig(
                Self.telemetry(
                    """
                      enabled: true
                      endpoint: \(collector.endpoint)
                      protocol: http/protobuf
                      export_interval_seconds: 1
                      signals: [metrics, logs]
                      resource_attributes:
                        deployment.environment: e2e
                    """))
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }

            let metrics = try await eventually("OTLP metrics", timeout: 45, interval: 1) {
                let posts = await collector.requests(to: "/v1/metrics")
                return posts.contains { $0.has("kinhin.fleet.active") } ? posts : nil
            }
            #expect(
                metrics.allSatisfy { $0.contentType.hasPrefix("application/x-protobuf") },
                "\(metrics.map(\.contentType))")
            #expect(metrics.contains { $0.has("kinhin.fleet.desired") && $0.has("kinhin.host.disk.free") })
            // The resource names the service and the host, and carries the user's attribute; nothing else owns service.name.
            let resource = try #require(metrics.last)
            for expected in ["service.name", "service.version", "host.name", "host.arch", "os.version"] {
                #expect(resource.has(expected), "resource attribute \(expected) is missing")
            }
            #expect(resource.has("deployment.environment") && resource.has("e2e"))
            #expect(resource.has("kinhin"), "service.name is kinhin")
            #expect(resource.has("telemetry.sdk"), "the SDK's own attributes are kept")

            // Logs: the daemon's own lines, with their component.
            let logs = try await eventually("OTLP logs", timeout: 45, interval: 1) {
                let posts = await collector.requests(to: "/v1/logs")
                return posts.contains { $0.has("serving RPC") } ? posts : nil
            }
            #expect(logs.contains { $0.has("kinhin.component") && $0.has("daemon") })

            // Periodic, not a one-off.
            let count = metrics.count
            try await eventually("a later metrics export", timeout: 20, interval: 1) {
                await collector.requests(to: "/v1/metrics").count > count ? true : nil as Bool?
            }
            // Traces were not selected, and with no job there is no per-job trace to send anyway.
            #expect(await collector.requests(to: "/v1/traces").isEmpty)
            #expect(!sandbox.log().contains("unreachable-forge-token"))
        }
    }

    @Test("collector headers come from OTEL_EXPORTER_OTLP_HEADERS and never reach the log or the collector's body")
    func otlpHeaders() async throws {
        let collector = try await OTLPCollectorStub()
        defer { collector.stop() }
        try await withSandbox { sandbox in
            try sandbox.writeConfig(
                Self.telemetry(
                    "  enabled: true\n  endpoint: \(collector.endpoint)\n  export_interval_seconds: 1\n  signals: [metrics, logs]"
                ))
            sandbox.setEnvironment("OTEL_EXPORTER_OTLP_HEADERS", "authorization=Bearer \(Self.secret),x-team=ci")
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            let posts = try await eventually("an authenticated export", timeout: 45, interval: 1) {
                let posts = await collector.requests()
                return posts.isEmpty ? nil : posts
            }
            for post in posts {
                #expect(post.headers["authorization"] == "Bearer \(Self.secret)", "\(post.path): \(post.headers)")
                #expect(post.headers["x-team"] == "ci")
                #expect(!post.has(Self.secret), "the credential must not be exported as data")
            }
            try await Task.sleep(for: .seconds(3))
            #expect(!sandbox.log().contains(Self.secret), "the credential must never be logged")
            #expect(!(await collector.requests(to: "/v1/logs")).contains { $0.has(Self.secret) })
        }
    }

    @Test("OTEL_* variables override the config: endpoint, signals, resource, and the off switch")
    func environmentOverrides() async throws {
        // Endpoint.
        let collector = try await OTLPCollectorStub()
        defer { collector.stop() }
        try await withSandbox { sandbox in
            let dead = try E2E.freePort()
            try sandbox.writeConfig(
                Self.telemetry(
                    "  enabled: true\n  endpoint: http://127.0.0.1:\(dead)\n  export_interval_seconds: 1\n  signals: [metrics]"
                )
            )
            sandbox.setEnvironment("OTEL_EXPORTER_OTLP_ENDPOINT", collector.endpoint)
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            try await eventually("metrics at the env-var endpoint", timeout: 45, interval: 1) {
                await collector.requests(to: "/v1/metrics").isEmpty ? nil as Bool? : true
            }
        }
        // Signals: OTEL_METRICS_EXPORTER=none removes metrics and leaves logs.
        let signals = try await OTLPCollectorStub()
        defer { signals.stop() }
        try await withSandbox { sandbox in
            try sandbox.writeConfig(
                Self.telemetry(
                    "  enabled: true\n  endpoint: \(signals.endpoint)\n  export_interval_seconds: 1\n  signals: [metrics, logs]"
                ))
            sandbox.setEnvironment("OTEL_METRICS_EXPORTER", "none")
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            try await eventually("logs to arrive", timeout: 45, interval: 1) {
                await signals.requests(to: "/v1/logs").isEmpty ? nil as Bool? : true
            }
            try await Task.sleep(for: .seconds(4))
            #expect(await signals.requests(to: "/v1/metrics").isEmpty, "OTEL_METRICS_EXPORTER=none removes metrics")
        }
        // Resource: OTEL_RESOURCE_ATTRIBUTES adds attributes but can never replace the service identity.
        let resource = try await OTLPCollectorStub()
        defer { resource.stop() }
        try await withSandbox { sandbox in
            try sandbox.writeConfig(
                Self.telemetry(
                    "  enabled: true\n  endpoint: \(resource.endpoint)\n  export_interval_seconds: 1\n  signals: [metrics]"
                ))
            sandbox.setEnvironment("OTEL_RESOURCE_ATTRIBUTES", "team=platform,service.name=evil")
            sandbox.setEnvironment("OTEL_SERVICE_NAME", "also-evil")
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            let posts = try await eventually("metrics with the env resource", timeout: 45, interval: 1) {
                let posts = await resource.requests(to: "/v1/metrics")
                return posts.contains { $0.has("team") } ? posts : nil
            }
            #expect(posts.allSatisfy { $0.has("platform") && !$0.has("evil") }, "service.name is not replaceable")
            #expect(sandbox.log().contains("service identity"), "the ignored identity override is logged")
        }
        // Off switch: OTEL_SDK_DISABLED wins over `enabled: true`.
        let off = try await OTLPCollectorStub()
        defer { off.stop() }
        try await withSandbox { sandbox in
            let port = try E2E.freePort()
            try sandbox.writeConfig(
                Self.telemetry(
                    "  enabled: true\n  endpoint: \(off.endpoint)\n  export_interval_seconds: 1\n  prometheus_listen: 127.0.0.1:\(port)"
                ))
            sandbox.setEnvironment("OTEL_SDK_DISABLED", "true")
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            try await Task.sleep(for: .seconds(8))
            #expect(await off.requests().isEmpty, "OTEL_SDK_DISABLED=true exports nothing")
            #expect(!E2E.isListening(port: port), "OTEL_SDK_DISABLED=true binds nothing")
        }
    }

    @Test("signals: [traces] alone sends no metrics or logs, and an idle daemon has no job trace to send")
    func signalSelection() async throws {
        let collector = try await OTLPCollectorStub()
        defer { collector.stop() }
        try await withSandbox { sandbox in
            try sandbox.writeConfig(
                Self.telemetry(
                    "  enabled: true\n  endpoint: \(collector.endpoint)\n  export_interval_seconds: 1\n  signals: [traces]"
                ))
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            try await Task.sleep(for: .seconds(10))
            #expect(await collector.requests(to: "/v1/metrics").isEmpty)
            #expect(await collector.requests(to: "/v1/logs").isEmpty)
            #expect(daemon.isRunning)
        }
    }

    @Test("protocol: grpc dials the collector over HTTP/2")
    func grpcDialsHTTP2() async throws {
        let probe = try await HTTP2PrefaceProbe()
        defer { probe.stop() }
        try await withSandbox { sandbox in
            try sandbox.writeConfig(
                Self.telemetry(
                    "  enabled: true\n  endpoint: http://127.0.0.1:\(probe.port)\n  protocol: grpc\n  export_interval_seconds: 1\n  signals: [metrics]"
                ))
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            try await eventually("the daemon to open an HTTP/2 connection", timeout: 45, interval: 1) {
                probe.sawHTTP2Preface ? true : nil as Bool?
            }
            #expect(daemon.isRunning, "a collector that is not a gRPC server must not hurt the daemon")
        }
    }

    @Test("an unreachable collector never hurts the fleet")
    func collectorDown() async throws {
        try await withSandbox { sandbox in
            let dead = try E2E.freePort()
            try sandbox.writeConfig(
                Self.telemetry(
                    "  enabled: true\n  endpoint: http://127.0.0.1:\(dead)\n  export_interval_seconds: 1\n  signals: [metrics, traces, logs]"
                ))
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            try await Task.sleep(for: .seconds(10))
            #expect(daemon.isRunning)
            let status = try await sandbox.kinhin(["status", "--json"], timeout: 15)
            #expect(status.ok, "the daemon still answers: \(status.output)")

            // The failure is not silent: `kinhin telemetry status` names it and exits 1.
            let report = try await eventually("telemetry status to report the export problem", timeout: 60, interval: 2)
            {
                let result = try await sandbox.kinhin(["telemetry", "status"], timeout: 15)
                return result.output.contains("export problem") ? result : nil
            }
            #expect(report.status == 1, "exit \(report.status): \(report.output)")
            #expect(report.output.contains("telemetry: on"), "\(report.output)")
            #expect(!report.output.contains("unreachable-forge-token"))
            let json = try await sandbox.kinhin(["telemetry", "status", "--json"], timeout: 15)
            let document = try #require(
                try JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any])
            let state = try #require(document["status"] as? [String: Any])
            #expect(state["enabled"] as? Bool == true)
            #expect((state["exportFailures"] as? Int ?? 0) >= 1)
            // The log carries each distinct problem once a minute, never every retry.
            let lines = sandbox.log().split(separator: "\n").filter { $0.contains("export problem") }
            #expect(!lines.isEmpty && lines.count <= 3, "\(lines.count) export-problem lines in the log")
        }
    }

    @Test("kinhin telemetry status reports a healthy pipeline and a disabled one")
    func telemetryStatusCommand() async throws {
        let collector = try await OTLPCollectorStub()
        defer { collector.stop() }
        try await withSandbox { sandbox in
            let port = try E2E.freePort()
            try sandbox.writeConfig(
                Self.telemetry(
                    "  enabled: true\n  endpoint: \(collector.endpoint)\n  export_interval_seconds: 1\n  signals: [metrics]\n  prometheus_listen: 127.0.0.1:\(port)"
                ))
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            let healthy = try await eventually("telemetry status", timeout: 60, interval: 1) {
                let result = try await sandbox.kinhin(["telemetry"], timeout: 15)
                return result.output.contains("telemetry: on") ? result : nil
            }
            #expect(healthy.ok, "exit \(healthy.status): \(healthy.output)")
            #expect(healthy.output.contains("metrics -> \(collector.endpoint)/v1/metrics"), "\(healthy.output)")
            #expect(healthy.output.contains("http://127.0.0.1:\(port)/metrics"), "\(healthy.output)")
            #expect(healthy.output.contains("no export problems reported"), "\(healthy.output)")
        }
        try await withSandbox { sandbox in
            try sandbox.writeConfig(Self.account)
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            let off = try await sandbox.kinhin(["telemetry"], timeout: 15)
            #expect(off.ok, "off is healthy: \(off.output)")
            #expect(off.output.contains("telemetry is off"), "\(off.output)")
        }
    }

    @Test("a stopping daemon flushes what it has not exported yet")
    func flushOnShutdown() async throws {
        let collector = try await OTLPCollectorStub()
        defer { collector.stop() }
        try await withSandbox { sandbox in
            // An hour between exports: anything the collector gets arrives because shutdown flushed it.
            try sandbox.writeConfig(
                Self.telemetry(
                    "  enabled: true\n  endpoint: \(collector.endpoint)\n  export_interval_seconds: 3600\n  signals: [metrics, logs]"
                ))
            let daemon = try await sandbox.startDaemon()
            try await Task.sleep(for: .seconds(3))
            #expect(await collector.requests().isEmpty, "nothing is exported before the interval")
            await daemon.stop()
            try await eventually("the shutdown flush", timeout: 30, interval: 1) {
                let posts = await collector.requests()
                let metrics = posts.contains { $0.path == "/v1/metrics" }
                let logs = posts.contains { $0.path == "/v1/logs" }
                return metrics && logs ? true : nil as Bool?
            }
        }
    }

    // MARK: - Off by default

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
                ? Self.telemetry(
                    """
                      enabled: false
                      endpoint: \(collector.endpoint)
                      export_interval_seconds: 1
                      signals: [metrics, traces, logs]
                      prometheus_listen: 127.0.0.1:\(port)
                    """) : Self.account
            try sandbox.writeConfig(section)
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }

            // Long enough for several 1s export intervals and a trace batch (5s by default) to have happened if enabled.
            try await Task.sleep(for: .seconds(12))
            #expect(!E2E.isListening(port: port), "the Prometheus port must not be bound with telemetry off")
            let posts = await collector.requests()
            #expect(posts.isEmpty, "the collector must receive nothing with telemetry off: \(posts)")
            #expect(daemon.isRunning, "the daemon is fine without telemetry")
            #expect(!sandbox.log().contains("telemetry enabled"))
        }
    }

    // MARK: - Local logs

    @Test("log_format: json writes one JSON object per line, even with telemetry off")
    func jsonLogs() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig(Self.telemetry("  log_format: json"))
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            try await eventually("the daemon to log", timeout: 30, interval: 1) {
                sandbox.log().contains("serving RPC") ? true : nil as Bool?
            }
            let lines = sandbox.log().split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            let objects = lines.compactMap { line -> [String: Any]? in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            }
            // The first lines (before the config is read) are the plain text the daemon starts with; everything after is JSON.
            let structured = objects.filter { $0["message"] != nil }
            #expect(!structured.isEmpty, "no JSON log line found:\n\(lines.suffix(8).joined(separator: "\n"))")
            for object in structured {
                for key in ["ts", "level", "component", "message"] {
                    #expect(object[key] is String, "\(key) missing in \(object)")
                }
            }
            #expect(!sandbox.log().contains("unreachable-forge-token"), "JSON lines are redacted like text lines")
        }
    }

    @Test("the default log format stays plain text")
    func textLogsByDefault() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig(Self.account)
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            try await eventually("the daemon to log", timeout: 30, interval: 1) {
                sandbox.log().contains("serving RPC") ? true : nil as Bool?
            }
            let line = try #require(sandbox.log().split(separator: "\n").first { $0.contains("serving RPC") })
            #expect(line.contains("[info] [daemon]"), "\(line)")
            #expect(!line.hasPrefix("{"))
        }
    }

    // MARK: - Validation

    @Test(
        "a bad telemetry: value is a config error (exit 3) that names the key",
        arguments: [
            ("protocol: carrier-pigeon", "telemetry.protocol"),
            ("endpoint: not a url", "telemetry.endpoint"),
            ("endpoint: ftp://collector:21", "telemetry.endpoint"),
            ("export_interval_seconds: 0", "telemetry.export_interval_seconds"),
            ("export_interval_seconds: 100000", "telemetry.export_interval_seconds"),
            ("signals: [metrics, spans]", "telemetry.signals"),
            ("prometheus_listen: somewhere", "telemetry.prometheus_listen"),
            ("prometheus_listen: 127.0.0.1:99999", "telemetry.prometheus_listen"),
            ("log_format: xml", "telemetry.log_format"),
            ("signals: [traces]\n  prometheus_listen: 9464", "telemetry.prometheus_listen"),
            ("job_attributes: [branch]", "telemetry.job_attributes"),
            ("resource_attributes:\n    service.name: mine", "service.name"),
            ("resource_attributes:\n    telemetry.sdk.version: 1", "telemetry.sdk.version"),
            ("enable: true", "telemetry.enable"),
        ])
    func badConfig(value: String, key: String) async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig(Self.telemetry("  enabled: true\n  \(value)"))
            let bad = try await sandbox.kinhin(["config", "validate"])
            #expect(bad.status == 3, "\(value): exit \(bad.status): \(bad.output)")
            #expect(bad.output.contains(key), "\(value): \(bad.output)")
        }
    }

    @Test("export_interval is accepted as an alias of export_interval_seconds")
    func intervalAlias() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig(Self.telemetry("  enabled: true\n  export_interval: 30"))
            #expect(try await sandbox.kinhin(["config", "validate"]).ok)
            try sandbox.writeConfig(
                Self.telemetry("  enabled: true\n  export_interval: 30\n  export_interval_seconds: 60"))
            #expect(try await sandbox.kinhin(["config", "validate"]).status == 3, "disagreeing keys are an error")
        }
    }

    @Test("every telemetry key together validates")
    func fullConfigValidates() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig(
                Self.telemetry(
                    """
                      enabled: true
                      endpoint: https://collector.example.com:4317
                      protocol: grpc
                      export_interval_seconds: 15
                      job_attributes: [repository, workflow]
                      signals: [metrics, traces, logs]
                      resource_attributes:
                        deployment.environment: lab
                        team: platform
                      prometheus_listen: 127.0.0.1:9464
                      log_format: json
                    """))
            let validated = try await sandbox.kinhin(["config", "validate"])
            #expect(validated.ok, "\(validated.output)")
        }
    }
}
