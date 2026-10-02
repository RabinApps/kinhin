import XCTest

@testable import KinhinKit

final class TartProcessSamplesTests: XCTestCase {
    func testParsesTartRunProcesses() {
        let text = """
              204800   1:02.50 /opt/homebrew/bin/tart run --no-graphics --net-softnet kinhin-1-a
               51200   0:10.00 /opt/homebrew/bin/tart run --no-graphics other-vm
                1024   0:00.10 /usr/bin/ssh kinhin-1-a
                 999   0:00.10 /opt/homebrew/bin/tart list kinhin-1-a
            """
        let samples = TartController.parseProcessSamples(text, names: ["kinhin-1-a"])
        XCTAssertEqual(samples, ["kinhin-1-a": ProcessSample(rssMB: 200, cpuSeconds: 62.5)])
    }

    func testParsesCPUTimeFormats() {
        XCTAssertEqual(TartController.parseCPUTime("0:01.50"), 1.5)
        XCTAssertEqual(TartController.parseCPUTime("1:00:00"), 3600)
        XCTAssertEqual(TartController.parseCPUTime("1-00:00:00"), 86400)
        XCTAssertNil(TartController.parseCPUTime("n/a"))
    }
}
