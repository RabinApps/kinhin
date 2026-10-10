import E2ESupport
import Foundation
import Testing

extension Infra {
    /// The core promise, per forge × runtime: a queued job is noticed, run inside a fresh guest, and everything is
    /// cleaned up afterwards. The judge is the forge itself, not kinhin's view of events.
    @Suite("Job lifecycle", .tags(.lifecycle))
    struct LifecycleTests {
        @Test(
            "a queued job runs inside the guest, then the guest and its runner are gone", arguments: LifecycleCase.all)
        func jobRunsInGuestAndIsTornDown(_ cell: LifecycleCase) async throws {
            try await Lane.with(forge: cell.forge, runtime: cell.runtime) { lane in
                let (nonce, proof) = try await lane.runJob(name: "hello")

                // The job really ran in the guest: the kernel it reports is the guest's, not this Mac's.
                #expect(proof.hasPrefix(cell.runtime.guestKernel), "proof \(nonce) was: \(proof)")
                if cell.runtime.isIsolated {
                    #expect(!proof.contains(ProcessInfo.processInfo.hostName), "the job ran on the host: \(proof)")
                } else {
                    // Host mode: the job must run inside its instance's scrubbed work directory in this sandbox.
                    let workDirs = "\(lane.sandbox.supportDirectory.lastPathComponent)/host-instances/kinhin-"
                    #expect(proof.contains(workDirs), "the host job ran outside its work directory: \(proof)")
                }

                // The instance that ran it goes away (after the forge's exit rule: deregistration or idle grace).
                let during = await Instances.running(cell.runtime, image: lane.image)
                try await eventually("the job's instance(s) \(during) to be deleted", timeout: 240, interval: 3) {
                    let now = await Instances.running(cell.runtime, image: lane.image)
                    return Set(during).isDisjoint(with: now) ? true : nil
                }
                // And the forge no longer lists their runners (kinhin deregisters what it spawned).
                try await eventually("the forge to forget runners \(during)", timeout: 120, interval: 3) {
                    let runners = try await lane.fixture.registeredRunners()
                    return Set(during).isDisjoint(with: runners) ? true : nil
                }

                // Secrets stay out of kinhin's own log.
                let token = await lane.fixture.token
                #expect(!lane.sandbox.log().contains(token), "the access token leaked into the log")
                #expect(lane.daemon?.isRunning == true, "the daemon died during the run")
            }
        }

        @Test(
            "a failing job is reported failed by the forge and does not wedge the fleet", arguments: LifecycleCase.all)
        func failingJobIsReportedAndTornDown(_ cell: LifecycleCase) async throws {
            try await Lane.with(forge: cell.forge, runtime: cell.runtime) { lane in
                let nonce = E2E.randomID()
                try await lane.fixture.pushWorkflow(
                    name: "boom", runtime: cell.runtime, nonce: nonce, script: "echo failing on purpose\nexit 1")
                let statuses = try await eventually("the forge to report the run failed", timeout: 480, interval: 4) {
                    let statuses = try await lane.fixture.runStatuses()
                    return statuses.contains("failure") ? statuses : nil
                }
                #expect(statuses.contains("failure"))
                #expect(try await lane.fixture.proof(nonce: nonce) == nil, "a failed job must not have produced proof")

                // The fleet recovers: a good job after the bad one still runs.
                let (_, proof) = try await lane.runJob(name: "after-failure")
                #expect(proof.hasPrefix(cell.runtime.guestKernel))
                #expect(lane.daemon?.isRunning == true)
            }
        }
    }
}
