import XCTest

@testable import KinhinKit

final class HealingBudgetTests: XCTestCase {
    private let signal = HealingSignal(kind: .diskPressure, detail: "full")
    private let fix = Remediation(.pruneToolchainCache)
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testTriesAreSpacedByTheCooldownAndCapped() {
        var budget = HealingBudget(maxAttempts: 2, cooldown: 60)
        XCTAssertTrue(budget.allows(signal, fix, now: start))
        budget.record(signal, fix, now: start)
        XCTAssertFalse(budget.allows(signal, fix, now: start.addingTimeInterval(30)), "inside the cooldown")
        XCTAssertTrue(budget.allows(signal, fix, now: start.addingTimeInterval(60)))
        budget.record(signal, fix, now: start.addingTimeInterval(60))
        XCTAssertTrue(budget.exhausted(signal, fix))
        XCTAssertFalse(budget.allows(signal, fix, now: start.addingTimeInterval(10_000)))
    }

    func testExhaustSpendsEveryTry() {
        var budget = HealingBudget(maxAttempts: 3, cooldown: 0)
        budget.exhaust(signal, fix)
        XCTAssertTrue(budget.exhausted(signal, fix))
    }

    func testPairsAreIndependent() {
        var budget = HealingBudget(maxAttempts: 1, cooldown: 0)
        budget.record(signal, fix, now: start)
        XCTAssertTrue(budget.exhausted(signal, fix))
        XCTAssertFalse(budget.exhausted(signal, Remediation(.pruneImages)))
        let other = HealingSignal(kind: .instanceGone, subject: "kinhin-1-a", detail: "x")
        XCTAssertFalse(budget.exhausted(other, fix))
    }

    func testAProblemThatGoesAwayStartsOverNextTime() {
        var budget = HealingBudget(maxAttempts: 1, cooldown: 0)
        budget.record(signal, fix, now: start)
        budget.forget(keepingOnly: [])
        XCTAssertFalse(budget.exhausted(signal, fix))
    }

    func testForgetKeepsLiveProblems() {
        var budget = HealingBudget(maxAttempts: 1, cooldown: 0)
        budget.record(signal, fix, now: start)
        budget.forget(keepingOnly: [signal.key])
        XCTAssertTrue(budget.exhausted(signal, fix))
    }

    func testAtLeastOneAttempt() {
        XCTAssertEqual(HealingBudget(maxAttempts: 0, cooldown: 0).maxAttempts, 1)
    }
}
