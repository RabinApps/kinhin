import E2ESupport
import Foundation
import Testing

extension Infra {
    /// Opt-in OpenTelemetry (issue #64) with a real job: a real forge, a real runtime and a daemon that exports to a local
    /// stand-in collector and a Prometheus endpoint. The judge is what the collector and `/metrics` received, set against what
    /// the forge says happened. The idle-daemon signals are in `TelemetryTests` (quick tier).
    @Suite("Telemetry with a job", .tags(.lifecycle))
    struct TelemetryLifecycleTests {
        /// The `telemetry:` block every scenario here uses: all three signals, a 1 s interval, Prometheus on `port`.
        private static func config(collector: OTLPCollectorStub, port: Int) -> String {
            """
            telemetry:
              enabled: true
              endpoint: \(collector.endpoint)
              export_interval_seconds: 1
              signals: [metrics, traces, logs]
              resource_attributes:
                deployment.environment: e2e
              prometheus_listen: 127.0.0.1:\(port)
            """
        }

        private static func scrape(_ port: Int) async -> String {
            (try? await Http.request("GET", "http://127.0.0.1:\(port)/metrics", timeout: 5))?.text ?? ""
        }

        /// The value of the first sample of `name` whose line also contains every fragment in `labels`.
        private static func sample(_ body: String, _ name: String, labels: [String] = []) -> Double? {
            for line in body.split(separator: "\n") where line.hasPrefix(name) {
                let text = String(line)
                guard labels.allSatisfy({ text.contains($0) }) else { continue }
                let fields = text.split(separator: " ")
                if fields.count >= 2, let value = Double(fields[1]) { return value }
            }
            return nil
        }

        @Test(
            "a job's phases, pickup and completion are measured and traced, with no instance id on any metric",
            arguments: LifecycleCase.all)
        func jobIsObserved(_ cell: LifecycleCase) async throws {
            let collector = try await OTLPCollectorStub()
            defer { collector.stop() }
            let port = try E2E.freePort()
            var options = Lane.Options()
            options.extraConfig = Self.config(collector: collector, port: port)
            try await Lane.with(forge: cell.forge, runtime: cell.runtime, options: options) { lane in
                let (_, proof) = try await lane.runJob(name: "observed")
                #expect(proof.hasPrefix(cell.runtime.guestKernel))

                // Metrics: the job was picked up and finished, and each kinhin-controlled phase was timed.
                let body = try await eventually("job metrics on /metrics", timeout: 300, interval: 3) {
                    let text = await Self.scrape(port)
                    let done = Self.sample(text, "kinhin_jobs_completed") ?? 0
                    let teardown = Self.sample(text, "kinhin_runner_teardown_duration_count")
                    return done >= 1 && teardown != nil ? text : nil
                }
                #expect((Self.sample(body, "kinhin_jobs_picked_up") ?? 0) >= 1, "\(body.prefix(2000))")
                for phase in ["clone", "boot", "register"] {
                    let count = Self.sample(
                        body, "kinhin_runner_provision_duration_count", labels: ["kinhin_runner_phase=\"\(phase)\""])
                    #expect((count ?? 0) >= 1, "phase \(phase) was never timed:\n\(body.prefix(2000))")
                }
                #expect((Self.sample(body, "kinhin_runner_teardown_duration_count") ?? 0) >= 1)
                #expect(body.contains("cicd_pipeline_run_duration"), "the job's run time is a histogram")
                // The verdict is the forge's: every forge but Bitbucket says success; a forge that cannot say reads `unknown`, never a guess.
                let verdict = cell.forge != .bitbucket ? "success" : "unknown"
                #expect(body.contains("cicd_pipeline_result=\"\(verdict)\""), "\(body.prefix(2000))")

                // Cardinality: instance names, runner names and job identifiers never become labels.
                let prefix = Instances.ownPrefix
                #expect(!body.contains(prefix), "an instance name leaked into /metrics:\n\(body.prefix(2000))")
                #expect(!body.contains("observed"), "a workflow or job name leaked into /metrics")
                #expect(!body.contains("vm_id") && !body.contains("trace_id") && !body.contains("span_id"))

                // Traces: one job trace with kinhin's measured phases; ids live on the spans.
                let traces = try await eventually("the job trace", timeout: 120, interval: 2) {
                    let posts = await collector.requests(to: "/v1/traces")
                    return posts.contains { $0.has("kinhin.job") && $0.has("teardown") } ? posts : nil
                }
                let names = Set(traces.flatMap(\.strings))
                for span in ["kinhin.job", "provision", "boot_ready", "registration", "run", "teardown"] {
                    #expect(names.contains { $0.contains(span) }, "span \(span) is missing from the trace")
                }
                #expect(traces.contains { $0.has("kinhin.vm.id") && $0.has(prefix) }, "the VM id is a span attribute")
                #expect(traces.contains { $0.has("kinhin.result") && $0.has("completed") })
                #expect(traces.contains { $0.has("cicd.pipeline.result") }, "the root span carries the job's result")
                #expect(traces.contains { $0.has("kinhin.runner.name") })
                #expect(traces.allSatisfy { $0.has("service.name") }, "spans carry the kinhin resource")

                // Logs: the instance's lifecycle lines carry its id and the trace they belong to.
                let logs = try await eventually("the instance's log records", timeout: 60, interval: 2) {
                    let posts = await collector.requests(to: "/v1/logs")
                    return posts.contains { $0.has("kinhin.vm.id") && $0.has(prefix) } ? posts : nil
                }
                #expect(
                    logs.contains { $0.has("lifecycle") || $0.has("booted") || $0.has("registration script finished") })

                // Secrets stay out of every channel.
                let token = await lane.fixture.token
                #expect(!body.contains(token), "the access token leaked into /metrics")
                for post in await collector.requests() {
                    #expect(!post.has(token), "the token was exported to \(post.path)")
                }
                #expect(!lane.sandbox.log().contains(token))
                #expect(lane.daemon?.isRunning == true)
            }
        }

        @Test(
            "a failing job still counts as picked up and completed, and is not a kinhin error",
            arguments: LifecycleCase.all)
        func failingJobIsNotAKinhinError(_ cell: LifecycleCase) async throws {
            let collector = try await OTLPCollectorStub()
            defer { collector.stop() }
            let port = try E2E.freePort()
            var options = Lane.Options()
            options.extraConfig = Self.config(collector: collector, port: port)
            try await Lane.with(forge: cell.forge, runtime: cell.runtime, options: options) { lane in
                let nonce = E2E.randomID()
                try await lane.fixture.pushWorkflow(
                    name: "boom", runtime: cell.runtime, nonce: nonce, script: "echo failing on purpose\nexit 1")
                _ = try await eventually("the forge to report the run failed", timeout: 480, interval: 4) {
                    let statuses = try await lane.fixture.runStatuses()
                    return statuses.contains("failure") ? statuses : nil
                }
                let body = try await eventually("the job to be counted", timeout: 300, interval: 3) {
                    let text = await Self.scrape(port)
                    return (Self.sample(text, "kinhin_jobs_completed") ?? 0) >= 1 ? text : nil
                }
                #expect((Self.sample(body, "kinhin_jobs_picked_up") ?? 0) >= 1)
                // `result` says the job ended, not that it passed: kinhin cannot see the workflow's verdict.
                #expect(
                    !body.contains("cicd_pipeline_result=\"success\""), "kinhin must not claim a failed job succeeded")
                if cell.forge != .bitbucket {
                    #expect(body.contains("cicd_pipeline_result=\"failure\""), "the forge's verdict is the result")
                }
                // A workflow that fails is the user's failure, not a kinhin error.
                #expect(
                    Self.sample(body, "cicd_system_errors") == nil,
                    "a failing workflow is not a kinhin error:\n\(body.prefix(2000))")

                // The fleet recovers, and the next job is counted too.
                _ = try await lane.runJob(name: "after-failure")
                try await eventually("the second job to be counted", timeout: 300, interval: 3) {
                    (Self.sample(await Self.scrape(port), "kinhin_jobs_completed") ?? 0) >= 2 ? true : nil as Bool?
                }
            }
        }
    }
}
