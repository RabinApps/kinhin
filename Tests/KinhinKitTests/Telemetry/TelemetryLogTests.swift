import Foundation
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class TelemetryLogTests: XCTestCase {
    override func tearDown() {
        Log.format = .text
        Log.telemetry = nil
        super.tearDown()
    }

    private func entry(_ message: String) -> Log.Entry {
        Log.Entry(timestamp: Date(timeIntervalSince1970: 0), level: "info", component: "engine", message: message)
    }

    func testTextFormatIsUnchanged() {
        XCTAssertTrue(entry("hi").formatted.hasSuffix("[info] [engine] hi"))
    }

    func testJSONLineCarriesIdentifiersWhenKnown() throws {
        let trace = TelemetrySpanContext(
            traceID: String(repeating: "b", count: 32), spanID: String(repeating: "c", count: 16))
        let context = Log.Context(vm: "kinhin-1-aa", trace: trace)
        context.job = "build"
        let fields = Log.Fields(component: "engine", context: context)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(entry("hello").json(fields).utf8)) as? [String: String])
        XCTAssertEqual(object["message"], "hello")
        XCTAssertEqual(object["level"], "info")
        XCTAssertEqual(object["vm"], "kinhin-1-aa")
        XCTAssertEqual(object["job"], "build")
        XCTAssertEqual(object["trace_id"], trace.traceID)
        XCTAssertEqual(object["span_id"], trace.spanID)
        XCTAssertEqual(object["ts"], "1970-01-01T00:00:00.000Z")
    }

    func testVMComesFromAnInstanceNamedComponent() {
        let fields = Log.Fields(component: "kinhin-1-dd", context: nil)
        XCTAssertEqual(fields.vm, "kinhin-1-dd")
        XCTAssertNil(Log.Fields(component: "engine", context: nil).vm)
    }

    func testSecretsNeverReachTheOTLPRecordOrJSON() throws {
        LogRedactor.registerSecret("super-secret-registration-value")
        defer { LogRedactor.forgetAllSecretsForTesting() }
        let recorder = RecordingTelemetryBackend()
        Log.telemetry = Telemetry(backend: recorder)
        Log.format = .json
        Log.warn("engine", "failed with super-secret-registration-value and ghp_abcdefghijklmnopqrstuvwxyz0123456789")
        let record = try XCTUnwrap(recorder.logs.last { $0.component == "engine" })
        XCTAssertFalse(record.message.contains("super-secret"), record.message)
        XCTAssertFalse(record.message.contains("ghp_abc"), record.message)
        XCTAssertEqual(record.level, .warn)
        let ring = Log.snapshot(limit: 5).last { $0.component == "engine" }
        XCTAssertEqual(ring?.message, record.message)
    }

    func testLifecycleContextReachesLogRecords() async throws {
        let recorder = RecordingTelemetryBackend()
        Log.telemetry = Telemetry(backend: recorder)
        let trace = TelemetrySpanContext(
            traceID: String(repeating: "1", count: 32), spanID: String(repeating: "2", count: 16))
        Log.$context.withValue(Log.Context(vm: "kinhin-9-ee", trace: trace)) {
            Log.info("fleet", "inside lifecycle")
        }
        let record = try XCTUnwrap(recorder.logs.last { $0.message == "inside lifecycle" })
        XCTAssertEqual(record.attributes["kinhin.vm.id"], "kinhin-9-ee")
        XCTAssertEqual(record.trace, trace)
    }

    func testDisabledHandleDropsLogs() {
        Log.telemetry = Telemetry.noop
        Log.info("engine", "nothing to export")
    }
}
