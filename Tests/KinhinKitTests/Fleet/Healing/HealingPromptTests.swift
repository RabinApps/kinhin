import XCTest

@testable import KinhinKit

/// The prompt every model-backed advisor is asked: budget, redaction, content.
final class HealingPromptTests: XCTestCase {
    private let request = HealingAdviceRequest(
        signal: HealingSignal(kind: .queueUnreadable, subject: "gitea", detail: "HTTP 503 from gitea.local"),
        candidates: [Remediation(.retryForgeAttach, subject: "gitea")],
        context: "warn engine: queue fetch failed for gitea: HTTP 503\nwarn engine: holding scale-down")

    func testThePromptFitsItsBudgetAndKeepsTheNewestLines() {
        let long = HealingAdviceRequest(
            signal: request.signal, candidates: request.candidates,
            context: String(repeating: "old line\n", count: 2000) + "newest line")
        let prompt = HealingPrompt.prompt(for: long, budget: 1200)
        XCTAssertLessThanOrEqual(prompt.count, 1200)
        XCTAssertTrue(prompt.hasSuffix("newest line"))
        XCTAssertTrue(prompt.contains("HTTP 503 from gitea.local"))
        XCTAssertTrue(prompt.contains("re-attach account gitea"))
    }

    func testThePromptIsRedacted() {
        let leaky = HealingAdviceRequest(
            signal: request.signal, candidates: request.candidates,
            context: "auth with ghp_abcdefghijklmnopqrstuvwxyz0123456789 failed")
        let prompt = HealingPrompt.prompt(for: leaky, budget: 4000)
        XCTAssertFalse(prompt.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
    }

    func testTheBudgetIsAQuarterOfTheWindowInCharacters() {
        XCTAssertEqual(HealingPrompt.budget(contextTokens: 4096), 8192)
    }
}
