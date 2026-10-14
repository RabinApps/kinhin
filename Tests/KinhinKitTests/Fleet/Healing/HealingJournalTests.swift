import XCTest

@testable import KinhinKit

final class HealingJournalTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("healing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)  // best-effort scratch cleanup
    }

    private func event(_ outcome: HealingEvent.Outcome, detail: String = "x") -> HealingEvent {
        HealingEvent(
            signal: HealingSignal(kind: .diskPressure, detail: "full"), remediation: Remediation(.pruneImages),
            source: .playbook, outcome: outcome, detail: detail)
    }

    func testTheJournalIsBounded() {
        var journal = HealingJournal()
        for _ in 0..<(HealingJournal.capacity + 5) { journal.append(event(.succeeded)) }
        XCTAssertEqual(journal.events.count, HealingJournal.capacity)
    }

    func testSaveAndLoadRoundTripOwnerOnly() throws {
        var journal = HealingJournal()
        journal.append(event(.succeeded))
        let url = HealingJournal.fileURL(in: directory)
        journal.save(to: url)

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertEqual(HealingJournal.load(from: url).events.map(\.id), journal.events.map(\.id))
    }

    func testOpenEventsOfAPreviousRunExpire() {
        var journal = HealingJournal()
        journal.append(event(.pending))
        journal.append(event(.surfaced))
        journal.append(event(.succeeded))
        let url = HealingJournal.fileURL(in: directory)
        journal.save(to: url)

        let loaded = HealingJournal.load(from: url)
        XCTAssertEqual(loaded.events.map(\.outcome), [.expired, .expired, .succeeded])
    }

    func testAnUnreadableJournalIsSetAsideAndStartsEmpty() throws {
        let url = HealingJournal.fileURL(in: directory)
        try Data("not json".utf8).write(to: url)

        XCTAssertTrue(HealingJournal.load(from: url, readOnly: true).events.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "a read-only view moves nothing")

        XCTAssertTrue(HealingJournal.load(from: url).events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the engine sets the bad file aside")
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(kept.contains { $0.hasPrefix("healing.json.corrupt-") }, "\(kept)")
    }

    func testDetailsAreRedacted() {
        let leaked = event(.failed, detail: "auth failed with ghp_abcdefghijklmnopqrstuvwxyz0123456789")
        XCTAssertFalse(leaked.detail.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
    }
}
