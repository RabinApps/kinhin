import XCTest

@testable import KinhinKit
@testable import kinhin_app

final class FleetSummaryTests: XCTestCase {
    private func status(
        running: Bool = true, paused: Bool = false, queue: Int = 0, cap: Int = 2, error: String? = nil
    ) -> FleetStatus {
        FleetStatus(running: running, paused: paused, queueDepth: queue, capacityCap: cap, lastError: error)
    }

    func testStoppedFleet() {
        XCTAssertEqual(FleetSummary.status(status(running: false)), "The fleet is stopped.")
    }

    func testRunningFleetReportsQueueAndCapacity() {
        XCTAssertEqual(
            FleetSummary.status(status(queue: 3)), "The fleet is running. 0 of 2 VMs active. 3 jobs queued.")
    }

    func testSingularQueue() {
        XCTAssertTrue(FleetSummary.status(status(queue: 1)).hasSuffix("1 job queued."))
    }

    func testPausedAndError() {
        let text = FleetSummary.status(status(paused: true, error: "boom"))
        XCTAssertTrue(text.hasPrefix("The fleet is paused."))
        XCTAssertTrue(text.hasSuffix("Last error: boom"))
    }

    func testPausedWithAutoResumeSpeaksTheCountdown() {
        var paused = status(paused: true)
        paused.autoResume = true
        XCTAssertTrue(
            FleetSummary.status(paused).contains(
                "Auto-resume is on — it will release the fleet when the queue is empty."))

        paused.pollInterval = 20
        XCTAssertTrue(
            FleetSummary.status(paused).contains(
                "Auto-resume is on — it re-checks the queue every 20s and resumes once it's empty."))
    }

    func testZeroCapacity() {
        XCTAssertTrue(FleetSummary.status(status(cap: 0)).contains("0 of 0 VMs active."))
    }

    func testPauseResultCoversNoOpsAndChanges() {
        XCTAssertEqual(
            FleetSummary.pauseResult(paused: true, before: status(paused: true)), "The fleet is already paused.")
        XCTAssertEqual(
            FleetSummary.pauseResult(paused: false, before: status(paused: false)), "The fleet isn't paused.")
        XCTAssertTrue(FleetSummary.pauseResult(paused: true, before: status()).hasPrefix("Paused."))
        XCTAssertEqual(FleetSummary.pauseResult(paused: false, before: status(paused: true)), "Resumed.")
        XCTAssertTrue(FleetSummary.pauseResult(paused: true, before: status(running: false)).contains("isn't running"))
    }

    func testDeleteResultCoversOutcomes() {
        XCTAssertEqual(FleetSummary.deleteResult(id: "vm-1", outcome: .deleted), "Deleted VM vm-1.")
        XCTAssertEqual(FleetSummary.deleteResult(id: "vm-1", outcome: .notFound), "No VM named vm-1 is in the fleet.")
        XCTAssertTrue(FleetSummary.deleteResult(id: "vm-1", outcome: .uncertain).contains("in progress"))
    }

    func testDeleteDialogNamesTheReleasePath() {
        XCTAssertEqual(
            FleetSummary.deleteResult(id: "vm-1", outcome: .deleted, pausedFirst: true, autoResume: true),
            "Deleted VM vm-1. The fleet is paused; auto-resume will release it when the queue is empty.")
        XCTAssertTrue(
            FleetSummary.deleteResult(id: "vm-1", outcome: .deleted, pausedFirst: true, autoResume: false)
                .contains("until you resume"))
        // Policy unknown (older daemon) reads like off — a hand resume.
        XCTAssertTrue(
            FleetSummary.deleteResult(id: "vm-1", outcome: .deleted, pausedFirst: true).contains("until you resume"))
        XCTAssertEqual(FleetSummary.deleteResult(id: "vm-1", outcome: .deleted), "Deleted VM vm-1.")
    }

    func testDiagnoseCoversLifecycleAndDetails() {
        var record = VMRecord(id: "vm-1", phase: .failed)
        record.job = "build"
        record.error = "tart run timed out"
        XCTAssertEqual(
            FleetSummary.diagnose(id: "vm-1", record: record),
            "VM vm-1 failed. Its last job was build. Last error: tart run timed out.")
        XCTAssertEqual(FleetSummary.diagnose(id: "vm-1", record: nil), "No VM named vm-1 is in the fleet.")
    }

    func testDiagnoseCoversQuietAndActiveStates() {
        var busy = VMRecord(id: "vm-1", phase: .busy)
        busy.job = "deploy"
        XCTAssertEqual(
            FleetSummary.diagnose(id: "vm-1", record: busy), "VM vm-1 is running a job. It is working on job deploy.")
        let waiting = VMRecord(id: "vm-2", phase: .ready)
        XCTAssertEqual(FleetSummary.diagnose(id: "vm-2", record: waiting), "VM vm-2 is ready and waiting for a job.")
    }

    func testAutoResumeResultCoversStates() {
        XCTAssertEqual(FleetSummary.autoResumeResult(on: true, outcome: .alreadyThere), "Auto-resume is already on.")
        XCTAssertEqual(FleetSummary.autoResumeResult(on: false, outcome: .alreadyThere), "Auto-resume is already off.")
        XCTAssertTrue(FleetSummary.autoResumeResult(on: true, outcome: .done).hasPrefix("Auto-resume is on."))
        XCTAssertTrue(FleetSummary.autoResumeResult(on: false, outcome: .done).hasPrefix("Auto-resume is off."))
    }

    func testDoctorSummary() {
        XCTAssertEqual(FleetSummary.doctor(ready: true, checks: []), "Everything looks good.")
        let bad = SetupCheckResult(id: "tart", title: "Tart", ok: false, detail: "not found", action: nil)
        let ok = SetupCheckResult(id: "arch", title: "Arch", ok: true, detail: "arm64", action: nil)
        XCTAssertEqual(FleetSummary.doctor(ready: false, checks: [ok, bad]), "Tart: not found")
        XCTAssertEqual(FleetSummary.doctor(ready: false, checks: [bad, bad]), "Tart: not found (and 1 more)")
    }
}
