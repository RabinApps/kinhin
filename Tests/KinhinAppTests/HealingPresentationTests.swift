import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The Diagnostics sheet's healing card: policy lines, what waits on the
/// user, and a bounded history of closed events.
final class HealingPresentationTests: XCTestCase {
    private func event(
        _ id: String, _ outcome: HealingEvent.Outcome, source: HealingEvent.Source = .playbook,
        explanation: String? = nil
    ) -> HealingEvent {
        HealingEvent(
            id: id, signal: HealingSignal(kind: .diskPressure, detail: "disk full"),
            remediation: Remediation(.pruneImages), source: source, outcome: outcome, detail: "detail of \(id)",
            explanation: explanation)
    }

    private func snapshot(
        enabled: Bool = true, automatic: Bool = true, advisor: String? = nil, events: [HealingEvent] = []
    ) -> HealingPresentation {
        HealingPresentation(HealingSnapshot(enabled: enabled, automatic: automatic, advisor: advisor, events: events))
    }

    // MARK: - Policy

    func testAutomaticWithAnAdvisorSaysBoth() {
        let healing = snapshot(advisor: "Apple Intelligence")
        XCTAssertEqual(healing.policy, "Safe fixes run automatically; the rest wait for your approval.")
        XCTAssertEqual(healing.advisor, "Advisor: Apple Intelligence")
    }

    func testApprovalOnlyWithoutAnAdvisorSaysRulesOnly() {
        let healing = snapshot(automatic: false)
        XCTAssertEqual(healing.policy, "Approval only: every fix waits for you.")
        XCTAssertEqual(healing.advisor, "Rules only — no advisor available.")
    }

    func testDisabledHealingSaysOffAndNamesNoAdvisor() {
        let healing = snapshot(enabled: false, advisor: "Apple Intelligence")
        XCTAssertTrue(healing.policy.hasPrefix("Off"))
        XCTAssertTrue(healing.policy.contains("healing.enabled"), "names the config key to turn it back on")
        XCTAssertNil(healing.advisor)
        XCTAssertFalse(healing.enabled)
    }

    // MARK: - Sections

    func testEventsLandInTheirSectionsNewestFirst() {
        let healing = snapshot(events: [
            event("h-6", .pending),
            event("h-5", .surfaced),
            event("h-4", .running),
            event("h-3", .succeeded),
            event("h-2", .pending),
            event("h-1", .failed),
        ])
        XCTAssertEqual(healing.pending.map(\.id), ["h-6", "h-2"])
        XCTAssertEqual(healing.surfaced.map(\.id), ["h-5"])
        XCTAssertEqual(healing.running.map(\.id), ["h-4"])
        XCTAssertEqual(healing.history.map(\.id), ["h-3", "h-1"], "only closed events are history")
        XCTAssertFalse(healing.isQuiet)
    }

    func testTheHistoryKeepsTheLastTenClosedEvents() {
        let events = (0..<15).map { event("h-\($0)", $0.isMultiple(of: 2) ? .succeeded : .resolved) }
        let healing = snapshot(events: events)
        XCTAssertEqual(healing.history.count, HealingPresentation.historyLimit)
        XCTAssertEqual(healing.history.first?.id, "h-0", "newest first, as the journal hands them over")
    }

    func testAnEmptyJournalIsQuiet() {
        XCTAssertTrue(snapshot().isQuiet)
    }

    // MARK: - Items

    func testOnlyTheAdvisorsExplanationIsShown() {
        let healing = snapshot(events: [
            event("h-2", .succeeded, source: .advisor, explanation: "the cache is the largest consumer"),
            event("h-1", .succeeded, source: .playbook, explanation: "not from the model"),
        ])
        XCTAssertEqual(healing.history.map(\.explanation), ["the cache is the largest consumer", nil])
    }

    func testItemsCarryTheDetailAndAnOutcomeLabel() throws {
        let item = try XCTUnwrap(snapshot(events: [event("h-1", .failed)]).history.first)
        XCTAssertEqual(item.detail, "detail of h-1")
        XCTAssertEqual(item.outcomeLabel, "Fix failed")
        XCTAssertFalse(item.ok)
        XCTAssertTrue(HealingPresentation.Item(event("h-2", .resolved)).ok, "a problem that went away is fine")
    }

    func testEveryOutcomeHasItsOwnLabel() {
        let outcomes: [HealingEvent.Outcome] = [
            .pending, .running, .succeeded, .failed, .surfaced, .dismissed, .resolved, .expired,
        ]
        let labels = Set(outcomes.map(HealingPresentation.label(for:)))
        XCTAssertEqual(labels.count, outcomes.count)
    }
}
