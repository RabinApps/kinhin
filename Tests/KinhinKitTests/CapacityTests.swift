import XCTest
@testable import KinhinKit

final class CapacityTests: XCTestCase {
    let host = HostResources(logicalCores: 10, memoryGB: 32, freeDiskGB: 200, arm64: true)

    func testCPUBound() {
        let plan = Capacity.plan(host: host, vmCPU: 4, vmMemoryGB: 8, reservedCPU: 2, reservedMemoryGB: 4, diskPerVMGB: 0, userMax: 10)
        // (10-2)/4 = 2 CPU, (32-4)/8 = 3 mem -> 2
        XCTAssertEqual(plan.maxConcurrent, 2)
        XCTAssertTrue(plan.bindingConstraint.contains("cpu"))
    }

    func testMemoryBound() {
        let plan = Capacity.plan(host: host, vmCPU: 2, vmMemoryGB: 16, reservedCPU: 2, reservedMemoryGB: 4, diskPerVMGB: 0, userMax: 10)
        // cpu (10-2)/2 = 4, mem (32-4)/16 = 1 -> 1
        XCTAssertEqual(plan.maxConcurrent, 1)
        XCTAssertTrue(plan.bindingConstraint.contains("memory"))
    }

    func testUserMaxBinds() {
        let plan = Capacity.plan(host: host, vmCPU: 2, vmMemoryGB: 4, reservedCPU: 2, reservedMemoryGB: 4, diskPerVMGB: 0, userMax: 1)
        XCTAssertEqual(plan.maxConcurrent, 1)
    }

    func testSingleVMDoesNotFit() {
        let tiny = HostResources(logicalCores: 4, memoryGB: 8, freeDiskGB: 50, arm64: true)
        let plan = Capacity.plan(host: tiny, vmCPU: 4, vmMemoryGB: 8, reservedCPU: 2, reservedMemoryGB: 4, diskPerVMGB: 0, userMax: 4)
        XCTAssertFalse(plan.fits)
        XCTAssertEqual(plan.maxConcurrent, 0)
    }

    func testDiskBoundCounts() {
        let plan = Capacity.plan(host: host, vmCPU: 2, vmMemoryGB: 4, reservedCPU: 2, reservedMemoryGB: 4, diskPerVMGB: 60, userMax: 10)
        // 200/60 = 3
        XCTAssertEqual(plan.maxConcurrent, 3)
        XCTAssertTrue(plan.bindingConstraint.contains("disk"))
    }

    func testZeroReserve() {
        let plan = Capacity.plan(host: host, vmCPU: 5, vmMemoryGB: 8, reservedCPU: 0, reservedMemoryGB: 0, diskPerVMGB: 0, userMax: 10)
        // cpu 10/5=2, mem 32/8=4 -> 2
        XCTAssertEqual(plan.maxConcurrent, 2)
    }
}
