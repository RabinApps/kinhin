import XCTest

@testable import KinhinKit

final class VMNamingTests: XCTestCase {
    func testVMNamesAreUniqueAndPrefixed() {
        let names = Set((0..<50).map { _ in VMRecord.newName() })
        XCTAssertEqual(names.count, 50)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("kinhin-") })
    }
}

extension VMNamingTests {
    func testGeneratedNamesAreValidIDsAndForeignNamesAreNot() {
        XCTAssertTrue(VMRecord.isValidID(VMRecord.newName()))
        for bad in [
            "", "kinhin-", "runner-1", "../kinhin-1", "kinhin-../x", "kinhin-1/2", "kinhin-1 2", "kinhin-1;id",
            "tahoe-base",
        ] {
            XCTAssertFalse(VMRecord.isValidID(bad), bad)
        }
    }
}
