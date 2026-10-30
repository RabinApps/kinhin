import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The Telemetry card's model: what it says for each way the exporters can be owned, and how the switch and the
/// Prometheus address edit config.yaml (only that key, validated, then pushed).
@MainActor
final class TelemetryModelTests: XCTestCase {
    private var dir: URL!
    private var url: URL!
    private var model: TelemetryModel!
    private var changes = 0
    private var reads = 0
    private var answer = TelemetryReading.noFleet

    private let base = """
        # my fleet
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: ["kinhin"]
        """

    private func status(
        enabled: Bool = true, signals: [String] = ["metrics", "traces"], prometheus: String? = nil,
        failures: Int = 0, lastFailureAt: Date? = nil, lastFailure: String? = nil
    ) -> TelemetryStatus {
        TelemetryStatus(
            enabled: enabled, signals: signals, otlpProtocol: "http/protobuf",
            endpoints: Dictionary(uniqueKeysWithValues: signals.map { ($0, "https://collector.example/v1/\($0)") }),
            prometheus: prometheus, jobAttributes: [], startedAt: Date(), exportFailures: failures,
            lastFailureAt: lastFailureAt, lastFailure: lastFailure)
    }

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-telemetry-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.yaml")
        try base.write(to: url, atomically: true, encoding: .utf8)
        changes = 0
        reads = 0
        answer = .noFleet
        model = TelemetryModel()
        model.configURL = url
        model.settle = .zero
        model.onChanged = { [unowned self] in changes += 1 }
        model.read = { [unowned self] in
            reads += 1
            return answer
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        model = nil
        try await super.tearDown()
    }

    private func write(_ text: String) throws { try text.write(to: url, atomically: true, encoding: .utf8) }
    private var onDisk: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    // MARK: - What it says

    func testOffEverywhereByDefault() async {
        await model.load()
        XCTAssertEqual(model.configEnabled, false)
        XCTAssertEqual(model.headline.text, "Telemetry is off.")
        XCTAssertNil(model.runningStatus)
        XCTAssertTrue(model.destinations.isEmpty)
        XCTAssertNil(model.problem)
        XCTAssertNil(model.ownerLine)
    }

    func testInProcessStatusShowsSignalsDestinationsAndPrometheus() async {
        answer = .inProcess(status(prometheus: "127.0.0.1:9464"))
        await model.load()
        XCTAssertEqual(model.headline.style, .ok)
        XCTAssertTrue(model.headline.text.contains("metrics"), model.headline.text)
        XCTAssertEqual(model.ownerLine, "Exported by this app.")
        XCTAssertEqual(model.destinations.map(\.signal), ["metrics", "traces"])
        XCTAssertEqual(model.destinations.first?.endpoint, "https://collector.example/v1/metrics")
        XCTAssertEqual(model.prometheusURL, "http://127.0.0.1:9464/metrics")
        XCTAssertEqual(model.problem?.style, .ok, "no problem reported reads as healthy")
    }

    func testDaemonStatusSaysTheDaemonExports() async {
        answer = .daemon(status())
        await model.load()
        XCTAssertEqual(model.ownerLine, "Exported by the daemon.")
        XCTAssertNil(model.prometheusURL)
    }

    func testRecentAndOldExportProblemsReadDifferently() async {
        let now = Date()
        model.now = { now }
        answer = .daemon(
            status(failures: 3, lastFailureAt: now.addingTimeInterval(-30), lastFailure: "connection refused"))
        await model.load()
        XCTAssertEqual(model.problem?.style, .error)
        XCTAssertTrue(model.problem?.text.contains("connection refused") == true)
        XCTAssertTrue(model.problem?.text.contains("3") == true)

        answer = .daemon(
            status(failures: 3, lastFailureAt: now.addingTimeInterval(-3600), lastFailure: "connection refused"))
        await model.load()
        XCTAssertEqual(model.problem?.style, .warn, "an hour old is history, not a live failure")
    }

    func testConfiguredOnButNotRunningWarns() async throws {
        try write(base + "\ntelemetry:\n  enabled: true\n")
        answer = .inProcess(.disabled)
        await model.load()
        XCTAssertEqual(model.configEnabled, true)
        XCTAssertEqual(model.headline.style, .warn)
        XCTAssertTrue(model.headline.text.contains("OTEL_SDK_DISABLED"), model.headline.text)
    }

    func testConfiguredOnWithNoFleetStartsWithTheFleet() async throws {
        try write(base + "\ntelemetry:\n  enabled: true\n")
        await model.load()
        XCTAssertTrue(model.headline.text.contains("starts with the fleet"), model.headline.text)
        XCTAssertEqual(model.headline.style, .secondary)
    }

    func testUnreachableDaemonIsShown() async {
        answer = .daemonUnreachable("could not connect")
        await model.load()
        XCTAssertEqual(model.headline.style, .warn)
        XCTAssertTrue(model.headline.text.contains("could not connect"), model.headline.text)
    }

    func testNothingTheCardShowsCanCarryHeaderValues() async {
        // The card renders only TelemetryStatus fields, which hold redacted endpoints and no headers.
        answer = .daemon(status())
        await model.load()
        let shown =
            ([model.headline.text, model.ownerLine, model.prometheusURL, model.problem?.text].compactMap { $0 }
            + model.destinations.map { "\($0.signal) \($0.endpoint)" }).joined(separator: "\n")
        XCTAssertFalse(shown.contains("Authorization"), shown)
        XCTAssertFalse(shown.contains("@"), "no userinfo in a URL: \(shown)")
    }

    func testUnreadableConfigIsReportedAndDisablesTheSwitch() async throws {
        try write("accounts: [unclosed")
        await model.load()
        XCTAssertNil(model.configEnabled)
        XCTAssertEqual(model.result.style, .error)
    }

    // MARK: - The switch

    func testTurningOnEditsOnlyThatKeyPushesAndReadsAgain() async throws {
        await model.load()
        let readsBefore = reads

        await model.setEnabled(true)

        XCTAssertTrue(onDisk.hasPrefix("# my fleet\naccounts:"), "comments and keys stay")
        XCTAssertTrue(onDisk.hasSuffix("telemetry:\n  enabled: true"), onDisk)
        XCTAssertEqual(try ConfigLoader.load(from: url).telemetry.enabled, true)
        XCTAssertEqual(model.configEnabled, true)
        XCTAssertEqual(changes, 1, "the edit is pushed to the engine or daemon once")
        XCTAssertGreaterThan(reads, readsBefore, "the status is read again after the owner applies it")
        XCTAssertEqual(model.result.style, .ok)
    }

    func testTurningOffKeepsTheRestOfTheSection() async throws {
        try write(base + "\ntelemetry:\n  enabled: true   # on\n  endpoint: http://localhost:4318\n")
        await model.load()

        await model.setEnabled(false)

        XCTAssertTrue(onDisk.contains("enabled: false # on\n  endpoint: http://localhost:4318"), onDisk)
        XCTAssertEqual(model.configEnabled, false)
        XCTAssertEqual(changes, 1)
    }

    func testARefusedEditWritesNothingAndPushesNothing() async throws {
        let flow = base + "\ntelemetry: {enabled: false}\n"
        try write(flow)
        await model.load()

        await model.setEnabled(true)

        XCTAssertEqual(onDisk, flow)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(model.result.style, .error)
        XCTAssertEqual(model.configEnabled, false, "the switch snaps back to what the file says")
    }

    // MARK: - The Prometheus address

    func testSavingAndClearingTheAddress() async throws {
        try write(base + "\ntelemetry:\n  enabled: true\n")
        await model.load()

        model.listenDraft = " 127.0.0.1:9464 "
        await model.applyListen()
        XCTAssertTrue(onDisk.contains("prometheus_listen: \"127.0.0.1:9464\""), onDisk)
        XCTAssertEqual(model.listenDraft, "127.0.0.1:9464")
        XCTAssertEqual(changes, 1)

        model.listenDraft = ""
        await model.applyListen()
        XCTAssertFalse(onDisk.contains("prometheus_listen"), onDisk)
        XCTAssertEqual(changes, 2)
    }

    func testUnchangedAddressWritesNothing() async throws {
        try write(base + "\ntelemetry:\n  enabled: true\n  prometheus_listen: \"9464\"\n")
        await model.load()
        XCTAssertEqual(model.listenDraft, "9464")
        await model.applyListen()
        XCTAssertEqual(changes, 0)
    }

    func testBadAddressIsRefusedAndTheTypedTextStaysForFixing() async throws {
        let yaml = base + "\ntelemetry:\n  enabled: true\n"
        try write(yaml)
        await model.load()

        model.listenDraft = "not an address"
        await model.applyListen()

        XCTAssertEqual(onDisk, yaml)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(model.result.style, .error)
        XCTAssertEqual(model.listenDraft, "not an address")
    }
}
