import E2ESupport
import Foundation
import Testing

extension Infra {
    /// How the engine behaves around the happy path: pause/resume, a daemon killed mid-run, the concurrency cap, a
    /// broken image. Gitea on Docker is the lane (hermetic, cheap, and the floor mode keeps one runner alive, which makes
    /// instance churn observable).
    @Suite("Fleet behavior", .tags(.fleet), .enabled(if: E2E.dockerAvailable, "needs Docker"))
    struct FleetBehaviorTests {
        private static func status(_ lane: Lane) async throws -> [String: Any] {
            let result = try await lane.sandbox.kinhin(["status", "--json"], timeout: 30)
            return (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any] ?? [:]
        }

        @Test("pause holds new runners, resume lets the fleet scale again")
        func pauseAndResume() async throws {
            try await Lane.with(forge: .gitea, runtime: .docker) { lane in
                let first = try await eventually("the floor runner to start", timeout: 120) {
                    let names = await Instances.docker(image: lane.image)
                    return names.isEmpty ? nil : names
                }
                let paused = try await lane.sandbox.kinhin(["pause"], timeout: 30)
                #expect(paused.ok, "pause failed: \(paused.output)")

                // With the fleet held, a runner that disappears is not replaced.
                _ = try await Shell.run("docker", ["rm", "-f"] + first, timeout: 60)
                try await Task.sleep(for: .seconds(25))
                let whilePaused = await Instances.docker(image: lane.image)
                #expect(whilePaused.isEmpty, "a paused fleet started \(whilePaused)")

                let resumed = try await lane.sandbox.kinhin(["resume"], timeout: 30)
                #expect(resumed.ok, "resume failed: \(resumed.output)")
                let replacement = try await eventually("a replacement runner after resume", timeout: 120) {
                    let names = await Instances.docker(image: lane.image)
                    return names.isEmpty ? nil : names
                }
                #expect(Set(replacement).isDisjoint(with: first))
            }
        }

        @Test("a SIGKILLed daemon leaves its runner behind, and the next daemon reconciles it away")
        func orphansAreReconciledAfterACrash() async throws {
            try await Lane.with(forge: .gitea, runtime: .docker) { lane in
                let orphans = try await eventually("the floor runner to start", timeout: 120) {
                    let names = await Instances.docker(image: lane.image)
                    return names.isEmpty ? nil : names
                }
                lane.daemon?.kill()
                #expect(
                    Set(await Instances.docker(image: lane.image)).isSuperset(of: orphans), "the crash removed them?")

                try await lane.startDaemon()
                try await eventually("the orphans \(orphans) to be reconciled", timeout: 120) {
                    let now = await Instances.docker(image: lane.image)
                    return Set(orphans).isDisjoint(with: now) ? true : nil
                }
                #expect(lane.sandbox.log().contains("reconciling existing instances"))
            }
        }

        @Test("the fleet never exceeds max_runners and still finishes every job")
        func concurrencyCapHolds() async throws {
            var options = Lane.Options()
            options.maxRunners = 1
            try await Lane.with(forge: .gitea, runtime: .docker, options: options) { lane in
                let first = E2E.randomID() + E2E.randomID()
                let second = E2E.randomID() + E2E.randomID()
                for (name, nonce) in [("cap-a", first), ("cap-b", second)] {
                    try await lane.fixture.pushWorkflow(
                        name: name, runsOn: lane.runtime.runsOn, nonce: nonce,
                        script: lane.fixture.proofScript(extra: "sleep 20"))
                }
                // Sample while both jobs are in flight: the cap is a hard ceiling on concurrent instances.
                var peak = 0
                let deadline = Date().addingTimeInterval(420)
                while Date() < deadline {
                    peak = max(peak, await Instances.docker(image: lane.image).count)
                    let firstDone = try await lane.fixture.proof(nonce: first) != nil
                    let secondDone = try await lane.fixture.proof(nonce: second) != nil
                    if firstDone && secondDone { break }
                    try await Task.sleep(for: .seconds(2))
                }
                #expect(peak <= 1, "saw \(peak) concurrent runners with max_runners: 1")
                #expect(try await lane.fixture.proof(nonce: first) != nil, "job A never finished")
                #expect(try await lane.fixture.proof(nonce: second) != nil, "job B never finished")
            }
        }

        @Test("an image that cannot start backs the fleet off instead of crashing or spinning")
        func brokenImageBacksOff() async throws {
            var options = Lane.Options()
            options.extraConfig = ""
            try await Lane.with(forge: .gitea, runtime: .docker, options: options) { lane in
                // Point the pool at an image that does not exist, then restart on that config.
                await lane.daemon?.stop()
                var config = try String(contentsOf: lane.sandbox.configURL, encoding: .utf8)
                config = config.replacingOccurrences(of: lane.image, with: "ke2e-no-such-image-\(E2E.randomID())")
                try lane.sandbox.writeConfig(config)
                try await lane.startDaemon()

                try await eventually("the engine to log that it is holding new runners", timeout: 180, interval: 3) {
                    lane.sandbox.log().contains("failed to start repeatedly") ? true : nil
                }
                #expect(lane.daemon?.isRunning == true, "the daemon crashed on a broken image")
                let status = try await lane.sandbox.kinhin(["status", "--json"], timeout: 30)
                #expect(status.ok, "the daemon stopped answering: \(status.output)")
            }
        }

        @Test("a forge that reports no queued jobs until a runner exists needs the floor (known limitation)")
        func giteaWithoutFloorIsBlind() async throws {
            var options = Lane.Options()
            options.minRunners = 0
            try await Lane.with(forge: .gitea, runtime: .docker, options: options) { lane in
                // Gitea 1.24 lists a waiting task only after a runner asks for it, so with min_runners: 0 kinhin never
                // sees the queued job and never starts a runner. Newer Gitea (1.25+) has /actions/jobs?status=waiting,
                // which kinhin does not use yet. When that lands this expectation flips and the test says so.
                await withKnownIssue("Gitea 1.24 hides queued jobs from the task API until a runner exists") {
                    let nonce = E2E.randomID() + E2E.randomID()
                    try await lane.fixture.pushWorkflow(
                        name: "blind", runsOn: lane.runtime.runsOn, nonce: nonce,
                        script: lane.fixture.proofScript(extra: ""))
                    _ = try await lane.fixture.awaitProof(nonce: nonce, timeout: 75)
                }
            }
        }
    }
}
