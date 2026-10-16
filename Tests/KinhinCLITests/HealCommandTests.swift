import Synchronization
import XCTest

@testable import KinhinKit
@testable import kinhin

/// `kinhin heal`: the view, the `--json` document and approve/dismiss, over
/// the shared `FleetServing` seam.
final class HealCommandTests: XCTestCase {
    /// Answers a fixed snapshot and records approve/dismiss calls. A spy for this suite only.
    private final class Recorder: FleetServing {
        let snapshot: HealingSnapshot
        let calls = Mutex<[String]>([])
        let failure: EngineError?

        init(_ snapshot: HealingSnapshot, failure: EngineError? = nil) {
            self.snapshot = snapshot
            self.failure = failure
        }

        func status() async throws -> FleetStatus {
            var status = FleetStatus()
            status.healing = snapshot
            return status
        }
        func start() async throws {}
        func stop() async throws {}
        func setPaused(_ paused: Bool) async throws {}
        func deleteVM(id: String) async throws {}
        func pipelineDetail(vmID: String) async throws -> PipelineDetail? { nil }
        func pipelineLog(vmID: String, jobID: String, stepIndex: Int?) async throws -> PipelineLog? { nil }
        func rotate(_ target: CredentialRotation.Target, token: String) async throws {}
        func requeueQueuedJobs(for forge: ForgeID) async throws {}
        func skipQueuedJobs(for forge: ForgeID) async throws {}
        func approveHealing(id: String) async throws {
            calls.withLock { $0.append("approve \(id)") }
            if let failure { throw failure }
        }
        func dismissHealing(id: String) async throws {
            calls.withLock { $0.append("dismiss \(id)") }
            if let failure { throw failure }
        }
        var logName: String { "recorder" }
    }

    private let now = Date(timeIntervalSince1970: 3_000_000)

    private func event(
        _ id: String, _ outcome: HealingEvent.Outcome, _ kind: Remediation.Kind?, detail: String,
        source: HealingEvent.Source = .playbook, explanation: String? = nil, ago: TimeInterval = 120
    ) -> HealingEvent {
        HealingEvent(
            id: id, signal: HealingSignal(kind: .diskPressure, detail: "full"),
            remediation: kind.map { Remediation($0) },
            source: source, outcome: outcome, detail: detail, explanation: explanation,
            at: now.addingTimeInterval(-ago))
    }

    private var snapshot: HealingSnapshot {
        HealingSnapshot(
            enabled: true, automatic: true, advisor: "apple-intelligence",
            events: [
                event("h-00000003", .pending, .pruneImages, detail: "prune unused images needs approval: full"),
                event(
                    "h-00000002", .surfaced, nil, detail: "queue unreadable", source: .advisor,
                    explanation: "the forge is down"),
                event("h-00000001", .succeeded, .pruneToolchainCache, detail: "freed 10 MB", ago: 7200),
            ])
    }

    func testTheViewListsWhatWaitsThenHistory() {
        let text = HealCommand.render(snapshot, now: now)
        XCTAssertTrue(text.hasPrefix("healing: safe fixes run on their own; apple-intelligence advises on the rest"))
        XCTAssertTrue(text.contains("waiting for approval (kinhin heal approve ID):\n  h-00000003  prune unused"))
        XCTAssertTrue(text.contains("needs you (kinhin heal dismiss ID once handled):\n  h-00000002  queue unreadable"))
        XCTAssertTrue(text.contains("advisor: the forge is down"))
        XCTAssertTrue(text.contains("recent:\n  h-00000001  succeeded 2h ago  freed 10 MB"))
    }

    func testOffAndEmptyStates() {
        XCTAssertEqual(
            HealCommand.render(HealingSnapshot(enabled: false, automatic: true, advisor: nil, events: [])),
            "healing is off (healing.enabled: false in config.yaml)")
        let empty = HealCommand.render(HealingSnapshot(enabled: true, automatic: false, advisor: nil, events: []))
        XCTAssertEqual(empty, "healing: every fix waits for approval; rules only\nnothing to heal")
    }

    func testTheJSONDocumentSplitsOpenEntries() async throws {
        let document = try await HealCommand.document(backend: Recorder(snapshot))
        XCTAssertTrue(document.daemon)
        XCTAssertEqual(document.pending.map(\.id), ["h-00000003"])
        XCTAssertEqual(document.surfaced.map(\.id), ["h-00000002"])
        XCTAssertEqual(document.events.count, 3)

        let json = try CLIJSON.string(document, dates: .iso8601)
        XCTAssertTrue(json.contains(#""remediation" : {"#))
        XCTAssertTrue(json.contains(#""kind" : "prune_images""#), "kinds keep their wire names")
    }

    func testApproveAndDismissGoToTheBackend() async throws {
        let backend = Recorder(snapshot)
        try await HealCommand.decide(["heal", "approve", "h-00000003"], approve: true, backend: backend)
        try await HealCommand.decide(["heal", "dismiss", "h-00000002"], approve: false, backend: backend)
        XCTAssertEqual(backend.calls.withLock { $0 }, ["approve h-00000003", "dismiss h-00000002"])
    }

    func testTheHealCommandIsInTheCatalog() throws {
        let heal = try XCTUnwrap(CommandCatalog.all.first { $0.name == "heal" })
        XCTAssertEqual(heal.subcommands.map(\.name), ["approve", "dismiss"])
        XCTAssertEqual(CLICommand.parse(["heal", "approve", "h-1"]), .heal)
    }
}
