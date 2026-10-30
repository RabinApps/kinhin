import Foundation
import XCTest

@testable import KinhinKit

/// `telemetry.persist`: spans and log records go through the SDK's on-disk queue, in an owner-only directory,
/// and a pipeline without it touches no disk. Delivery after an outage is the SDK's own (tested upstream) and is
/// not exercised here: that needs a collector.
final class TelemetryPersistTests: XCTestCase {
    private var queue: URL!

    override func setUpWithError() throws {
        queue = FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: queue)  // temp directory cleanup
    }

    private func settings(persist: Bool, signals: Set<TelemetrySettings.Signal>) -> TelemetrySettings {
        var settings = TelemetryResolver.resolve(
            KinhinConfig.TelemetryConfig(enabled: true, signals: signals, persist: persist), environment: [:],
            host: TelemetryHostInfo(hostName: "h", architecture: "arm64", osVersion: "26.0.0"))
        // Nothing listens on the discard port: exports fail, which is the outage the queue is for.
        settings.endpoints = settings.endpoints.mapValues { _ in URL(string: "http://127.0.0.1:9/v1/x")! }
        return settings
    }

    func testPersistCreatesOwnerOnlyQueuesForSpansAndLogs() async throws {
        let backend = try OTelBackend(settings: settings(persist: true, signals: [.traces, .logs]), queueRoot: queue)
        defer { Task { await backend.shutdown() } }
        for name in ["traces", "logs"] {
            let path = queue.appendingPathComponent(name).path
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700, name)
        }
    }

    func testSpansAndLogsAreWrittenToTheQueueWhenTheCollectorIsDown() async throws {
        let backend = try OTelBackend(settings: settings(persist: true, signals: [.traces, .logs]), queueRoot: queue)
        let span = backend.startSpan("kinhin.job", start: nil, attributes: ["kinhin.pool": .string("tart")])
        span.end(at: nil, error: nil)
        backend.emit(
            log: TelemetryLogRecord(
                timestamp: Date(), level: .warn, component: "engine", message: "queued while the collector is down",
                attributes: [:], trace: nil))
        await backend.shutdown()  // flushes processors, which hand their batches to the queue
        func fileCount(_ name: String) -> Int {
            let directory = queue.appendingPathComponent(name)
            return (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
        }
        XCTAssertGreaterThan(fileCount("traces"), 0, "the span is on disk")
        XCTAssertGreaterThan(fileCount("logs"), 0, "the log record is on disk")
    }

    func testWithoutPersistNothingIsCreatedOnDisk() async throws {
        let backend = try OTelBackend(settings: settings(persist: false, signals: [.traces, .logs]), queueRoot: queue)
        await backend.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.path))
    }

    func testAnUnusableQueueDirectoryFailsTheStart() throws {
        // A file where the directory must go.
        try Data().write(to: queue)
        XCTAssertThrowsError(
            try OTelBackend(settings: settings(persist: true, signals: [.traces]), queueRoot: queue)
        ) {
            guard case TelemetryError.queueUnavailable = $0 else { return XCTFail("\($0)") }
        }
    }

    func testTheQueueHasASizeCapAndAnAgeLimit() {
        // The preset's own fields are internal to the SDK; the constants it is built from are the contract.
        XCTAssertLessThanOrEqual(TelemetryTransport.maxQueueBytes, 64 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(TelemetryTransport.maxQueueAge, 24 * 60 * 60)
    }
}
