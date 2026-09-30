import XCTest

@testable import KinhinKit

final class AutoscalerTests: XCTestCase {
    func testZeroQueueScalesToZero() {
        XCTAssertEqual(Autoscaler.desiredCount(queueDepth: 0, minRunners: 0, maxRunners: 4, capacityCap: 4), 0)
    }

    func testScalesWithQueue() {
        XCTAssertEqual(Autoscaler.desiredCount(queueDepth: 3, minRunners: 0, maxRunners: 4, capacityCap: 4), 3)
    }

    func testQueueBeyondMaxIsClamped() {
        XCTAssertEqual(Autoscaler.desiredCount(queueDepth: 10, minRunners: 0, maxRunners: 4, capacityCap: 4), 4)
    }

    func testCapacityCapBindsBeforeUserMax() {
        XCTAssertEqual(Autoscaler.desiredCount(queueDepth: 10, minRunners: 0, maxRunners: 8, capacityCap: 2), 2)
    }

    func testMinRunnersHoldsFloor() {
        XCTAssertEqual(Autoscaler.desiredCount(queueDepth: 0, minRunners: 2, maxRunners: 4, capacityCap: 4), 2)
    }

    func testMinRunnersYieldsToCapacity() {
        XCTAssertEqual(Autoscaler.desiredCount(queueDepth: 0, minRunners: 3, maxRunners: 4, capacityCap: 1), 1)
    }

    func testActiveCountIgnoresDeletingAndFailed() {
        let records: [VMRecord] = [
            VMRecord(id: "a", phase: .ready),
            VMRecord(id: "b", phase: .busy),
            VMRecord(id: "c", phase: .booting),
            VMRecord(id: "d", phase: .deleting),
            VMRecord(id: "e", phase: .failed),
        ]
        XCTAssertEqual(Autoscaler.activeCount(records), 3)
    }

    // MARK: - Many-to-one (runners_per_vm)

    /// rpv=1 must reproduce the classic one-VM-per-job behavior exactly.
    func testRunnersPerVMOneMatchesLegacyBehavior() {
        for queue in [0, 1, 3, 7, 20] {
            for minR in [0, 2] {
                for maxR in [1, 4] {
                    for cap in [1, 3, 8] {
                        XCTAssertEqual(
                            Autoscaler.desiredCount(
                                queueDepth: queue, minRunners: minR, maxRunners: maxR, capacityCap: cap, runnersPerVM: 1
                            ),
                            Autoscaler.desiredCount(
                                queueDepth: queue, minRunners: minR, maxRunners: maxR, capacityCap: cap),
                            "rpv=1 diverged from legacy at q=\(queue) min=\(minR) max=\(maxR) cap=\(cap)"
                        )
                    }
                }
            }
        }
    }

    func testRunnersPerVMHalvesVMsNeeded() {
        // 12 queued jobs, 6 runners per VM → 2 VMs (bounded by max_runners).
        XCTAssertEqual(
            Autoscaler.desiredCount(queueDepth: 12, minRunners: 0, maxRunners: 4, capacityCap: 4, runnersPerVM: 6), 2)
        // Odd remainder rounds up: 5 jobs at rpv=2 → 3 VMs.
        XCTAssertEqual(
            Autoscaler.desiredCount(queueDepth: 5, minRunners: 0, maxRunners: 4, capacityCap: 4, runnersPerVM: 2), 3)
        // min_runners still counts VMs, not jobs.
        XCTAssertEqual(
            Autoscaler.desiredCount(queueDepth: 0, minRunners: 2, maxRunners: 4, capacityCap: 4, runnersPerVM: 3), 2)
        // Capacity still clamps VM count regardless of density.
        XCTAssertEqual(
            Autoscaler.desiredCount(queueDepth: 40, minRunners: 0, maxRunners: 8, capacityCap: 2, runnersPerVM: 8), 2)
    }

    func testJobCapacityMath() {
        XCTAssertEqual(Autoscaler.jobCapacity(maxRunners: 2, capacityCap: 2, runnersPerVM: 6), 12)
        XCTAssertEqual(Autoscaler.jobCapacity(maxRunners: 4, capacityCap: 2, runnersPerVM: 3), 6, "capacity caps VMs")
        XCTAssertEqual(Autoscaler.jobCapacity(maxRunners: 2, capacityCap: 4, runnersPerVM: 1), 2, "classic shape")
    }
}
