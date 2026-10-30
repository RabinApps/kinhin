import Foundation
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// `telemetry.log_level` gates only what is forwarded to the OTLP log pipeline, independently of `Log.minLevel`.
final class TelemetryLogLevelTests: XCTestCase {
    private var savedMinLevel = Log.minLevel
    private var savedEcho = Log.echoToStderr

    override func setUp() {
        super.setUp()
        savedMinLevel = Log.minLevel
        savedEcho = Log.echoToStderr
        Log.echoToStderr = false
    }

    override func tearDown() {
        Log.minLevel = savedMinLevel
        Log.echoToStderr = savedEcho
        Log.telemetry = nil
        super.tearDown()
    }

    private func attach(level: Log.Level) -> RecordingTelemetryBackend {
        let recorder = RecordingTelemetryBackend()
        let handle = Telemetry(backend: recorder)
        handle.setLogLevel(level)
        Log.telemetry = handle
        return recorder
    }

    func testDefaultLevelIsInfo() throws {
        XCTAssertEqual(KinhinConfig.TelemetryConfig.default.logLevel, .info)
        let settings = TelemetryResolver.resolve(
            KinhinConfig.TelemetryConfig(enabled: true), environment: [:],
            host: TelemetryHostInfo(hostName: "h", architecture: "arm64", osVersion: "26.0.0"))
        XCTAssertEqual(settings.logLevel, .info)
    }

    func testRecordsBelowTheLevelAreNotForwarded() {
        Log.minLevel = .debug
        let recorder = attach(level: .warn)
        Log.debug("level-test", "debug line")
        Log.info("level-test", "info line")
        Log.warn("level-test", "warn line")
        Log.error("level-test", "error line")
        XCTAssertEqual(
            recorder.logs.filter { $0.component == "level-test" }.map(\.message), ["warn line", "error line"])
    }

    func testTheOTLPLevelDoesNotChangeTheLocalLog() {
        Log.minLevel = .debug
        _ = attach(level: .error)
        Log.info("level-local", "kept locally")
        XCTAssertTrue(
            Log.snapshot(limit: 20).contains { $0.component == "level-local" && $0.message == "kept locally" },
            "the ring (and so the file) still gets what Log.minLevel allows")
    }

    func testTheLocalLevelDoesNotChangeWhatIsForwarded() {
        Log.minLevel = .error
        let recorder = attach(level: .debug)
        Log.debug("level-remote", "debug for the collector only")
        XCTAssertEqual(
            recorder.logs.filter { $0.component == "level-remote" }.map(\.message), ["debug for the collector only"])
        XCTAssertFalse(
            Log.snapshot(limit: 50).contains { $0.component == "level-remote" },
            "below Log.minLevel, so not in the local log")
    }

    func testNothingIsForwardedWhileTelemetryIsOff() {
        Log.minLevel = .debug
        let recorder = RecordingTelemetryBackend()
        Log.telemetry = Telemetry(backend: recorder, enabled: false)
        Log.error("level-off", "no pipeline")
        XCTAssertTrue(recorder.logs.isEmpty, "a disabled handle forwards nothing")
    }
}
