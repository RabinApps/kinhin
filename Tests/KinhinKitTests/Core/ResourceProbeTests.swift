import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ResourceProbeTests: XCTestCase {
    func testResourceProbeReturnsSaneHostData() {
        let host = ResourceProbe().snapshot()
        XCTAssertGreaterThan(host.logicalCores, 0)
        XCTAssertGreaterThan(host.memoryGB, 0)
        XCTAssertGreaterThanOrEqual(host.freeDiskGB, 0)
        #if arch(arm64)
            XCTAssertTrue(host.arm64)
        #endif
    }
}
