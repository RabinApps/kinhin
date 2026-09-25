import XCTest

@testable import KinhinKit

final class TartParsingTests: XCTestCase {
    func testTartListParsing() {
        let output = """
            tahoe-base\tghcr.io/cirruslabs/macos-tahoe-base:latest\trunning\t4\t8\t64
            kinhin-1717-abc\ttahoe-base\tsuspended\t2\t4\t64
            """
        let vms = TartController.parseList(output)
        XCTAssertEqual(vms.count, 2)
        XCTAssertEqual(vms[0].name, "tahoe-base")
        XCTAssertEqual(vms[0].status, "running")
        XCTAssertEqual(vms[0].cpu, 4)
        XCTAssertEqual(vms[1].memoryMB, 4096)
    }

    func testIPv4Validation() {
        XCTAssertTrue(TartController.isValidIPv4("192.168.64.3"))
        XCTAssertFalse(TartController.isValidIPv4("999.1.1.1"))
        XCTAssertFalse(TartController.isValidIPv4("abc"))
        XCTAssertFalse(TartController.isValidIPv4("1.2.3"))
    }
}
