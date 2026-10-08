import XCTest

@testable import KinhinKit

final class TartGuestMemoryTests: XCTestCase {
    func testSumsActiveWiredAndCompressorPages() {
        let text = """
            16384
            Mach Virtual Memory Statistics: (page size of 16384 bytes)
            Pages free:                               1000.
            Pages active:                             65536.
            Pages inactive:                           5000.
            Pages wired down:                         32768.
            Pages occupied by compressor:             16384.
            """
        // (65536 + 32768 + 16384) pages * 16 KiB = 1792 MiB
        XCTAssertEqual(TartController.parseGuestMemoryUsedMB(text), 1792)
    }

    func testUnparseableOutputIsNil() {
        XCTAssertNil(TartController.parseGuestMemoryUsedMB(""))
        XCTAssertNil(TartController.parseGuestMemoryUsedMB("oops\nnothing"))
        XCTAssertNil(TartController.parseGuestMemoryUsedMB("16384\nPages free: 5."))
    }
}
