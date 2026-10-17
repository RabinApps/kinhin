import XCTest

@testable import KinhinKit

/// The System 1 wording: one criterion per option, each naming its precondition, and the header in front of the problem.
final class DecisionPromptTests: XCTestCase {
    private let candidates = [
        Remediation(.recycleInstance, subject: "kinhin-1-a"),
        Remediation(.pruneImages),
    ]

    func testEveryOptionHasACriterion() {
        let criteria = DecisionPrompt.criteria(for: candidates)
        XCTAssertEqual(Set(criteria.keys), ["recycle_instance", "prune_images", "none"])
    }

    func testACandidateSaysWhenItIsRight() throws {
        let criteria = DecisionPrompt.criteria(for: candidates)
        let recycle = try XCTUnwrap(criteria["recycle_instance"])
        XCTAssertTrue(recycle.hasPrefix("Pick recycle_instance only when "))
        XCTAssertTrue(recycle.contains("missing from the list"))
    }

    func testNoneNamesTheCasesThatRuleEveryOptionOut() throws {
        let none = try XCTUnwrap(DecisionPrompt.criteria(for: candidates)["none"])
        XCTAssertTrue(none.hasPrefix("Pick none when "))
        XCTAssertTrue(none.contains("401 or 403"))
        XCTAssertTrue(none.contains("no real failure"))
    }

    func testTheStateStartsWithTheHeaderThenTheProblem() {
        let state = DecisionPrompt.state(for: OllamaTestSupport.request, budget: 8192)
        XCTAssertTrue(state.hasPrefix(DecisionPrompt.header + "\n\n"))
        XCTAssertTrue(state.contains("HTTP 503 from gitea.local"))
    }

    func testTheStateStaysWithinItsBudgetIncludingTheHeader() {
        let long = HealingAdviceRequest(
            signal: OllamaTestSupport.request.signal, candidates: candidates,
            context: String(repeating: "old line\n", count: 5000))
        let state = DecisionPrompt.state(for: long, budget: 1000)
        XCTAssertLessThanOrEqual(state.count, 1000)
    }
}
