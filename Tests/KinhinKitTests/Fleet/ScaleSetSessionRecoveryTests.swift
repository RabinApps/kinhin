import XCTest

@testable import KinhinKit

/// A run that dies without deleting its scale-set session leaves GitHub
/// answering 409 to the next create. The listener records the session it
/// holds and deletes a leftover one before creating, so a restart attaches at
/// once; with no record it keeps retrying and says why.
final class ScaleSetSessionRecoveryTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-ss-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func store(scaleSet: String = "kinhin") -> ScaleSetSessionStore {
        ScaleSetSessionStore(directory: directory, account: "acme", scaleSet: scaleSet)
    }

    // MARK: - Store

    func testStoreRoundTripsAndClears() {
        let store = store()
        XCTAssertNil(store.load())
        store.save(.init(scaleSetId: 17, sessionId: "s-old", ownerName: "acme"))
        XCTAssertEqual(store.load()?.sessionId, "s-old")
        XCTAssertEqual(store.load()?.scaleSetId, 17)
        store.clear()
        XCTAssertNil(store.load())
    }

    func testStoreIgnoresACorruptFileAndIsolatesScaleSets() throws {
        let one = store(scaleSet: "kinhin")
        let two = store(scaleSet: "kinhin-docker")
        XCTAssertNotEqual(one.url, two.url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: one.url)
        XCTAssertNil(one.load())
        one.save(.init(scaleSetId: 1, sessionId: "a", ownerName: "o"))
        XCTAssertNil(two.load())
    }

    func testStoreFileNameIsSafeForOddNames() {
        let odd = ScaleSetSessionStore(directory: directory, account: "a/b ../c", scaleSet: "x y")
        XCTAssertEqual(odd.url.deletingLastPathComponent().path, directory.path)
        XCTAssertFalse(odd.url.lastPathComponent.contains("/"))
    }

    // MARK: - Listener

    func testLeftoverSessionIsDeletedBeforeCreating() async throws {
        let client = ConflictingClient(conflictsRemaining: 0)
        store().save(.init(scaleSetId: 17, sessionId: "s-stale", ownerName: "acme"))
        let listener = makeListener(client)
        await listener.start()
        let calls = await client.calls
        XCTAssertEqual(calls, ["delete:s-stale", "create"], "reap first, then create")
        XCTAssertEqual(store().load()?.sessionId, "s-new", "the new session is what is on record now")
        await listener.stop()
        XCTAssertNil(store().load(), "a clean stop clears the record")
        let after = await client.calls
        XCTAssertEqual(after.last, "delete:s-new")
    }

    func testRecordForAnotherScaleSetIsLeftAlone() async throws {
        let client = ConflictingClient(conflictsRemaining: 0)
        store().save(.init(scaleSetId: 99, sessionId: "s-other", ownerName: "acme"))
        let listener = makeListener(client)
        await listener.start()
        let calls = await client.calls
        XCTAssertEqual(calls, ["create"])
        await listener.stop()
    }

    func testConflictWithNoRecordIsReportedAndRecordsNothing() async throws {
        let client = ConflictingClient(conflictsRemaining: 100)
        let listener = makeListener(client)
        await listener.start()
        XCTAssertNil(store().load(), "nothing recorded when no session was created")
        let first = await listener.reportedError()?.errorDescription ?? ""
        XCTAssertTrue(first.contains("still holds an earlier session"), first)
        await listener.stop()
    }

    private func makeListener(_ client: ConflictingClient) -> GitHubScaleSetListener {
        GitHubScaleSetListener(
            client: client, scaleSetIdSupplier: { 17 }, ownerName: "acme", pollInterval: .seconds(99),
            sessionStore: store())
    }
}

/// Creates succeed after `conflictsRemaining` 409s; records the calls it saw.
private actor ConflictingClient: GitHubScaleSetServing {
    private(set) var calls: [String] = []
    private var conflictsRemaining: Int

    init(conflictsRemaining: Int) { self.conflictsRemaining = conflictsRemaining }

    func exchangeRegistrationToken(registrationToken: String) async throws -> GitHubScaleSetRegistrationToken {
        GitHubScaleSetRegistrationToken(
            token: "jwt", expiresAt: .now + 3600, actionsUrl: URL(string: "https://actions.invalid")!)
    }
    func ensureScaleSet(name: String, labels: [String], runnerGroup: String?) async throws -> GitHubScaleSet {
        GitHubScaleSet(id: 17, name: name, runnerGroupName: "default", labels: labels)
    }
    func patchScaleSet(id: Int, labels: [String]) async throws {}
    func createSession(scaleSetId: Int, ownerName: String) async throws -> GitHubScaleSetSession {
        calls.append("create")
        if conflictsRemaining > 0 {
            conflictsRemaining -= 1
            throw GitHubScaleSetClientError.sessionConflict
        }
        return GitHubScaleSetSession(
            sessionId: "s-new", messageQueueUrl: URL(string: "https://example.invalid/msgs")!,
            messageQueueAccessToken: "mq")
    }
    func refreshSession(scaleSetId: Int, sessionId: String) async throws -> GitHubScaleSetSession {
        throw GitHubError.notFound("session")
    }
    func deleteSession(scaleSetId: Int, sessionId: String) async throws { calls.append("delete:\(sessionId)") }
    func pollMessages(session: GitHubScaleSetSession, lastMessageId: String?, maxCapacity: Int) async throws
        -> [GitHubScaleSetMessage]
    { [] }
    func ackMessage(session: GitHubScaleSetSession, messageId: String) async throws {}
    func generateJitConfig(scaleSetId: Int, name: String, workFolder: String) async throws -> GitHubScaleSetJitConfig {
        GitHubScaleSetJitConfig(encodedJitConfig: "jit")
    }
    func scaleSetStatistics(scaleSetId: Int) async throws -> GitHubScaleSetStatistics {
        GitHubScaleSetStatistics(totalAssignedJobs: 0, activeNodesCount: 0)
    }
}
