import E2ESupport
import Foundation
import Testing

extension Infra {
    /// User-facing features exercised against a live fleet with a real job in flight: the read-only commands an
    /// operator (or an agent) runs while work happens, and routing between two pools.
    @Suite("Features on a live fleet", .tags(.fleet), .enabled(if: E2E.dockerAvailable, "needs Docker"))
    struct FeatureTests {
        private static func json(_ text: String) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }

        @Test("status, pipeline and logs describe a busy fleet; requeue/skip refuse a forge without a queue API")
        func readCommandsOnABusyFleet() async throws {
            var options = Lane.Options()
            options.minRunners = 0
            options.forgeImage = GiteaFixture.floorFreeGiteaImage
            try await Lane.with(forge: .gitea, runtime: .docker, options: options) { lane in
                let nonce = E2E.randomID() + E2E.randomID()
                try await lane.fixture.pushWorkflow(
                    name: "busy", runtime: .docker, nonce: nonce, script: lane.fixture.proofScript(extra: "sleep 40"))

                // While the job runs: one record, busy, and the forge's queue drained.
                let busy = try await eventually("a busy instance in status --json", timeout: 240, interval: 2) {
                    let result = try await lane.sandbox.kinhin(["status", "--json"], timeout: 30)
                    guard let status = Self.json(result.stdout), let fleet = status["fleet"] as? [String: Any],
                        let records = fleet["records"] as? [[String: Any]],
                        let record = records.first(where: { ($0["phase"] as? String) == "busy" })
                    else { return nil as String? }
                    return record["id"] as? String
                }

                let pipeline = try await lane.sandbox.kinhin(["pipeline", "--json"], timeout: 60)
                #expect(pipeline.ok, "pipeline --json failed: \(pipeline.output)")
                // One entry per busy instance. Gitea gives job-level detail only, so the entry may be just the VM.
                let entries =
                    (try? JSONSerialization.jsonObject(with: Data(pipeline.stdout.utf8))) as? [[String: Any]] ?? []
                #expect(
                    entries.contains { ($0["vm"] as? String) == busy },
                    "the busy instance \(busy) is missing from the pipeline: \(pipeline.output.prefix(800))")

                let token = await lane.fixture.token
                let logs = try await lane.sandbox.kinhin(["logs", "-n", "200"], timeout: 30)
                #expect(logs.ok, "logs failed: \(logs.output)")
                #expect(logs.output.contains(busy), "logs never mention \(busy): \(logs.output.suffix(800))")
                #expect(!logs.output.contains(token), "logs printed the token")

                // Gitea has no queue API for these (GitHub only): a clear refusal, and the fleet keeps working.
                for command in ["requeue", "skip"] {
                    let refused = try await lane.sandbox.kinhin([command, "gitea", "--yes"], timeout: 60)
                    #expect(!refused.ok, "\(command) on Gitea should be refused: \(refused.output)")
                    #expect(!refused.output.isEmpty, "\(command) refused silently")
                }
                #expect(lane.daemon?.isRunning == true)

                let proof = try await lane.fixture.awaitProof(nonce: nonce, timeout: 300)
                #expect(proof.hasPrefix("Linux"))
            }
        }

        static let routingForges: [ForgeKind] = [.gitea, .forgejo].filter {
            E2E.selected("KINHIN_E2E_FORGES", $0.rawValue)
        }

        /// Precedence is workflow route → repo route → label → default. A job asking only for the shared labels
        /// (`linux`) can run in either pool, so where it lands shows which rule won.
        @Test(
            "a repo route beats the default pool, and a workflow route beats the repo route",
            .enabled(if: E2E.appleContainerAvailable, "needs Apple container as the second pool"),
            arguments: routingForges)
        func routesWinInPrecedenceOrder(_ forge: ForgeKind) async throws {
            var options = Lane.Options()
            options.minRunners = 0
            options.maxRunners = 2
            options.startDaemon = false
            if forge == .gitea { options.forgeImage = GiteaFixture.floorFreeGiteaImage }
            try await Lane.with(forge: forge, runtime: .docker, options: options) { lane in
                let account = await lane.fixture.account
                let containerImage = try await ImageBaker.shared.ensure(.appleContainer, accounts: [account])
                defer { Task { await Instances.removeAll(.appleContainer, image: containerImage) } }
                var config = try String(contentsOf: lane.sandbox.configURL, encoding: .utf8)
                config = config.replacingOccurrences(
                    of: "runtimes:\n  default: docker\n",
                    with: """
                        runtimes:
                          default: docker
                          routes:
                            - pattern: "\(account.scope)@via-workflow-route"
                              runtime: docker
                            - pattern: "\(account.scope)"
                              runtime: appleContainer

                        """)
                config += """
                    container:
                      image: "\(containerImage)"
                      base_image: "ubuntu:24.04"
                      cpus: 2
                      memory_gb: 2

                    """
                try lane.sandbox.writeConfig(config)
                let validated = try await lane.sandbox.kinhin(["config", "validate"])
                try #require(validated.ok, "the two-pool config is invalid: \(validated.output)")
                try await lane.startDaemon()

                /// Runs a markerless job and reports which pool's instance served it.
                func landing(_ workflow: String) async throws -> RuntimeKind? {
                    let nonce = E2E.randomID() + E2E.randomID()
                    try await lane.fixture.pushWorkflow(
                        name: workflow, labels: ["linux"], nonce: nonce, script: lane.fixture.proofScript(extra: ""))
                    var seen: RuntimeKind?
                    let deadline = Date().addingTimeInterval(360)
                    while Date() < deadline {
                        if seen == nil {
                            if !(await Instances.docker(image: lane.image)).isEmpty { seen = .docker }
                            if !(await Instances.appleContainers(image: containerImage)).isEmpty {
                                seen = .appleContainer
                            }
                        }
                        if try await lane.fixture.proof(nonce: nonce) != nil { return seen }
                        try await Task.sleep(for: .seconds(2))
                    }
                    Issue.record("job \(workflow) never ran\n\(await lane.fixture.debugState())\n\(lane.logTail())")
                    return seen
                }

                #expect(try await landing("via-repo-route") == .appleContainer, "the repo route should win")
                // Let the first instance go before the next job, so the sampling sees only the new one.
                try await eventually("the first instance to go", timeout: 240, interval: 3) {
                    let docker = await Instances.docker(image: lane.image)
                    let containers = await Instances.appleContainers(image: containerImage)
                    return docker.isEmpty && containers.isEmpty ? true : nil
                }
                // Neither Gitea's nor Forgejo's queue names a job's workflow (only its file, on the run), so a
                // workflow route cannot match there; the repo route keeps the job. Pinned so a fix shows up.
                let workflowRouted = try await landing("via-workflow-route")
                withKnownIssue("Gitea and Forgejo job lists carry no workflow name, so workflow routes never match") {
                    #expect(workflowRouted == .docker, "the workflow route should win")
                }
            }
        }
    }
}
