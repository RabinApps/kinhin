import Synchronization
import XCTest

@testable import KinhinKit

final class HostUsageProbeTests: XCTestCase {
    private func probe(ticks: [CPUTicks]) -> HostUsageProbe {
        let queue = Locked(ticks)
        return HostUsageProbe(
            readTicks: { queue.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
            readMemory: { (usedBytes: 8 << 30, totalBytes: 16 << 30) })
    }

    func testFirstSampleHasNoCPUPercent() {
        let usage = probe(ticks: [CPUTicks(busy: 100, total: 200)]).sample()
        XCTAssertNil(usage?.cpuPercent)
        XCTAssertEqual(usage?.memoryUsedGB, 8)
        XCTAssertEqual(usage?.memoryTotalGB, 16)
    }

    func testSecondSampleUsesTickDelta() {
        let probe = probe(ticks: [CPUTicks(busy: 100, total: 200), CPUTicks(busy: 150, total: 300)])
        _ = probe.sample()
        XCTAssertEqual(probe.sample()?.cpuPercent ?? -1, 50, accuracy: 0.001)
    }

    func testUnreadableMemoryYieldsNil() {
        let probe = HostUsageProbe(readTicks: { nil }, readMemory: { nil })
        XCTAssertNil(probe.sample())
    }

    func testSystemProbeReturnsSaneValues() {
        let probe = HostUsageProbe()
        let usage = probe.sample()
        XCTAssertGreaterThan(usage?.memoryTotalGB ?? 0, 0)
        XCTAssertLessThanOrEqual(usage?.memoryUsedGB ?? .infinity, usage?.memoryTotalGB ?? 0)
    }
}
