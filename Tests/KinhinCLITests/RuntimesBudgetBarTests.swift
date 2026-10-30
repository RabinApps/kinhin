import XCTest

@testable import kinhin

// `kinhin runtimes`' budget bar rounded the fraction first and scaled after
// (`x.rounded() * 100`), so every share that was not ~0% or ~100% rendered as
// 0% or 100%: a ⅓ share printed as an empty bar at 0%. The rounding belongs on
// the scaled value, and the whole bar (cells, percent, clamping) is testable.
final class RuntimesBudgetBarTests: XCTestCase {
    func testSharesRoundOnTheScaledValue() {
        XCTAssertEqual(RuntimesCommand.budgetBar(1.0 / 3.0), "██████░░░░░░░░░░░░░░ 33%")
        XCTAssertEqual(RuntimesCommand.budgetBar(2.0 / 3.0), "█████████████░░░░░░░ 67%")
        XCTAssertEqual(RuntimesCommand.budgetBar(0.02), "░░░░░░░░░░░░░░░░░░░░ 2%")
        XCTAssertEqual(RuntimesCommand.budgetBar(0.99), "███████████████████░ 99%")
        XCTAssertEqual(RuntimesCommand.budgetBar(1.0), "████████████████████ 100%")
    }

    func testBarCellsStaysWithinTenBlocks() {
        XCTAssertEqual(RuntimesCommand.budgetBar(0.5), "██████████░░░░░░░░░░ 50%")
    }

    func testAnImpossiblyLargeShareClampsToAFullBar() {
        XCTAssertEqual(RuntimesCommand.budgetBar(1.5), "████████████████████ 150%")
    }
}
