import XCTest

@testable import KinhinKit

final class RuntimeSectionVerdictTests: XCTestCase {
    func testReadyHasNoFix() {
        let verdict = RuntimeSectionVerdict.from(health: .ready)
        XCTAssertEqual(verdict, RuntimeSectionVerdict(state: .ready, ok: true, fix: nil))
    }

    func testMissingCarriesTheHealthAdviceOrTheOverride() {
        let health = RuntimeHealth.missing(tool: "docker", fix: "brew install docker")
        XCTAssertEqual(RuntimeSectionVerdict.from(health: health).fix, "brew install docker")
        XCTAssertEqual(RuntimeSectionVerdict.from(health: health, missingFix: "repair it").fix, "repair it")
        XCTAssertEqual(RuntimeSectionVerdict.from(health: health).state, .missing)
        XCTAssertFalse(RuntimeSectionVerdict.from(health: health).ok)
    }

    func testBrokenCarriesTheReasonAndIgnoresTheOverride() {
        let verdict = RuntimeSectionVerdict.from(health: .broken("daemon down"), missingFix: "ignored")
        XCTAssertEqual(verdict, RuntimeSectionVerdict(state: .broken, ok: false, fix: "daemon down"))
    }

    func testStateEncodesAsTheHistoricalJSONStrings() throws {
        for (state, text) in [(RuntimeSectionState.ready, "ready"), (.missing, "missing"), (.broken, "broken")] {
            let data = try JSONEncoder().encode([state])
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"\(text)\"]")
        }
    }
}
