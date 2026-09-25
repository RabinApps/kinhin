import XCTest

@testable import KinhinKit

final class VMNamingTests: XCTestCase {
    func testVMNamesAreUniqueAndPrefixed() {
        let names = Set((0..<50).map { _ in VMRecord.newName() })
        XCTAssertEqual(names.count, 50)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("kinhin-") })
    }
}
