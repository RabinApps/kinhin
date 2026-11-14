import Synchronization
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The Alerts card's model: the list shows hosts only, the sheet validates through the editor and stores tokens in
/// the Keychain (never in the file), and Test goes through the chosen webhook.
@MainActor
final class AlertsModelTests: XCTestCase {
    private var dir: URL!
    private var url: URL!
    private var model: AlertsModel!
    private var changes = 0
    private var stored: [(token: String, account: String)] = []

    private let base = """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: ["kinhin"]
        """

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-alerts-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.yaml")
        try base.write(to: url, atomically: true, encoding: .utf8)
        changes = 0
        stored = []
        model = AlertsModel()
        model.configURL = url
        model.onChanged = { [unowned self] in changes += 1 }
        model.storeToken = { [unowned self] token, account in stored.append((token, account)) }
        model.reload()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        model = nil
        try await super.tearDown()
    }

    private var onDisk: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    private func add(
        _ name: String, url: String = "https://hooks.example.com/secret/path", events: Set<AlertEventKind>? = nil,
        token: String = ""
    ) async {
        model.beginAdd()
        model.draft?.name = name
        model.draft?.url = url
        model.draft?.token = token
        if let events {
            model.draft?.allEvents = false
            model.draft?.events = events
        }
        await model.saveDraft()
    }

    func testStartsOffAndEmpty() {
        XCTAssertEqual(model.configEnabled, false)
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testAddingAWebhookWritesItAndShowsOnlyTheHost() async {
        await add("ops", events: [.disk, .queue])
        XCTAssertNil(model.draft)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(model.rows.map(\.name), ["ops"])
        XCTAssertEqual(model.rows.first?.endpoint, "https://hooks.example.com")
        XCTAssertFalse(model.summary(of: model.rows[0]).contains("secret"))
        XCTAssertEqual(model.rows.first?.events, [.disk, .queue])
        XCTAssertTrue(onDisk.contains("# ") || onDisk.contains("accounts:"))
    }

    func testTokenGoesToTheKeychainNotTheFile() async {
        await add("ops", token: "s3cret")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.token, "s3cret")
        XCTAssertEqual(stored.first?.account, "ops")
        XCTAssertFalse(onDisk.contains("s3cret"))
        XCTAssertTrue(onDisk.contains("headers_keychain: \"ops\""))
    }

    func testANewWebhookNeverTakesAnotherWebhooksKeychainAccount() async throws {
        await add("ops", token: "one")
        // Rename it: the rename keeps `ops` as its Keychain account.
        model.beginEdit("ops")
        model.draft?.name = "backup"
        await model.saveDraft()
        XCTAssertTrue(onDisk.contains("headers_keychain: \"ops\""))
        // A new webhook called `ops` must not overwrite that account.
        await add("ops", token: "two")
        XCTAssertEqual(stored.map(\.account), ["ops", "ops-2"])
        XCTAssertEqual(stored.last?.token, "two")
    }

    func testBadInputStaysInTheSheetWithEntriesIntact() async {
        await add("ops", url: "http://example.com/x")
        XCTAssertNotNil(model.draft)
        XCTAssertEqual(model.draft?.name, "ops")
        XCTAssertFalse(model.draftProblem.isEmpty)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(onDisk, base)
    }

    func testDuplicateNameIsRefused() async {
        await add("ops")
        await add("ops", url: "https://other.example.com/x")
        XCTAssertNotNil(model.draft)
        XCTAssertEqual(model.rows.count, 1)
    }

    func testNoEventTypeSelectedIsRefusedInTheSheet() async {
        await add("ops", events: [])
        XCTAssertNotNil(model.draft)
        XCTAssertFalse(model.draftProblem.isEmpty)
    }

    func testEditingKeepsTheStoredURLWhenLeftEmpty() async {
        await add("ops")
        model.beginEdit("ops")
        XCTAssertEqual(model.draft?.url, "", "the URL is never shown")
        model.draft?.minSeverity = .critical
        await model.saveDraft()
        XCTAssertNil(model.draft)
        XCTAssertEqual(model.rows.first?.minSeverity, .critical)
        XCTAssertTrue(onDisk.contains("https://hooks.example.com/secret/path"))
    }

    func testSwitchNeedsAWebhook() async {
        await model.setEnabled(true)
        XCTAssertEqual(model.result.style, .error)
        XCTAssertEqual(model.configEnabled, false)
        await add("ops")
        await model.setEnabled(true)
        XCTAssertEqual(model.configEnabled, true)
    }

    func testRemoveDropsTheRow() async {
        await add("ops")
        await add("backup", url: "https://backup.example.com/x")
        await model.remove("ops")
        XCTAssertEqual(model.rows.map(\.name), ["backup"])
    }

    func testTestGoesThroughTheNamedWebhookAndShowsTheOutcome() async {
        await add("ops")
        let asked = Mutex<String?>(nil)
        model.sendTest = { webhook in
            asked.withLock { $0 = webhook.name }
            return ["test alert sent to ops (https://hooks.example.com)"]
        }
        await model.test("ops")
        XCTAssertEqual(asked.withLock { $0 }, "ops")
        XCTAssertEqual(model.result.style, .ok)
        model.sendTest = { _ in throw AlertError.badStatus(500) }
        await model.test("ops")
        XCTAssertEqual(model.result.style, .error)
        XCTAssertNil(model.testing)
    }

    func testUnreadableConfigIsSaidNotDefaulted() throws {
        try "alerts: [".write(to: url, atomically: true, encoding: .utf8)
        model.reload()
        XCTAssertNil(model.configEnabled)
        XCTAssertEqual(model.result.style, .error)
    }
}
