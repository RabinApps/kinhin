import Foundation
import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class TelemetryServiceTests: XCTestCase {
    private final class Factory: @unchecked Sendable {
        let made = Mutex<[RecordingTelemetryBackend]>([])
        let fail = Mutex(false)
        func make(_ settings: TelemetrySettings) throws -> any TelemetryBackend {
            if fail.withLock({ $0 }) { throw TelemetryError.listenFailed("port in use") }
            let backend = RecordingTelemetryBackend()
            made.withLock { $0.append(backend) }
            return backend
        }
        var backends: [RecordingTelemetryBackend] { made.withLock { $0 } }
    }

    private func service(_ factory: Factory, env: [String: String] = [:]) -> TelemetryService {
        TelemetryService(
            environment: { env }, host: TelemetryHostInfo(hostName: "h", architecture: "arm64", osVersion: "26.0.0"),
            makeBackend: { try factory.make($0) })
    }

    private var on: KinhinConfig.TelemetryConfig { KinhinConfig.TelemetryConfig(enabled: true) }

    override func tearDown() {
        Log.format = .text
        Log.telemetry = nil
        super.tearDown()
    }

    func testDisabledStartsNothing() async {
        let factory = Factory()
        let service = service(factory)
        let outcome = await service.apply(.default)
        XCTAssertEqual(outcome, .disabled)
        XCTAssertTrue(factory.backends.isEmpty, "no exporter or listener is created while disabled")
        XCTAssertFalse(service.telemetry.isEnabled)
        // The no-op handle accepts every call and records nothing.
        service.telemetry.add(.jobsPickedUp)
        XCTAssertTrue(service.telemetry.startSpan("x").context == nil)
    }

    func testStartReloadAndShutdownLifecycle() async {
        let factory = Factory()
        let service = service(factory)

        let first = await service.apply(on)
        XCTAssertEqual(first, .started)
        XCTAssertEqual(factory.backends.count, 1)
        XCTAssertTrue(service.telemetry.isEnabled)

        // Same settings again: nothing is rebuilt.
        let same = await service.apply(on)
        XCTAssertEqual(same, .unchanged)
        XCTAssertEqual(factory.backends.count, 1)

        // Changed settings: the old pipeline is shut down, exactly one new one runs.
        var changed = on
        changed.exportIntervalSeconds = 10
        let reloaded = await service.apply(changed)
        XCTAssertEqual(reloaded, .started)
        XCTAssertEqual(factory.backends.count, 2)
        XCTAssertEqual(factory.backends[0].shutdownCount, 1)
        XCTAssertEqual(factory.backends[1].shutdownCount, 0)

        // The stable handle now records into the new backend only.
        service.telemetry.add(.jobsPickedUp)
        XCTAssertEqual(factory.backends[0].counters.count, 0)
        XCTAssertEqual(factory.backends[1].counters.count, 1)

        // Turning it off stops it.
        let off = await service.apply(.default)
        XCTAssertEqual(off, .disabled)
        XCTAssertEqual(factory.backends[1].shutdownCount, 1)
        XCTAssertFalse(service.telemetry.isEnabled)

        await service.shutdown()
        XCTAssertEqual(factory.backends.map(\.shutdownCount), [1, 1], "shutdown after stop does not double-stop")
    }

    func testShutdownFlushesTheRunningPipeline() async {
        let factory = Factory()
        let service = service(factory)
        await service.apply(on)
        await service.shutdown()
        XCTAssertEqual(factory.backends.first?.shutdownCount, 1)
    }

    func testStartFailureLeavesTelemetryOff() async {
        let factory = Factory()
        factory.fail.withLock { $0 = true }
        let service = service(factory)
        let outcome = await service.apply(on)
        guard case .failed(let message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.contains("port in use"))
        XCTAssertFalse(service.telemetry.isEnabled)
    }

    func testSDKDisabledEnvironmentKeepsItOff() async {
        let factory = Factory()
        let service = service(factory, env: ["OTEL_SDK_DISABLED": "true"])
        let outcome = await service.apply(on)
        XCTAssertEqual(outcome, .disabled)
        XCTAssertTrue(factory.backends.isEmpty)
    }

    func testLogFormatAppliesEvenWhenTelemetryIsOff() async {
        let service = service(Factory())
        var config = KinhinConfig.TelemetryConfig.default
        config.logFormat = .json
        await service.apply(config)
        XCTAssertEqual(Log.format, .json)
    }

    func testLogsReachTheBackendOnlyWhileLogsAreExported() async throws {
        let factory = Factory()
        let service = service(factory)
        var config = on
        config.signals = [.metrics, .logs]
        await service.apply(config)
        Log.warn("engine", "hello from the test")
        let backend = try XCTUnwrap(factory.backends.first)
        XCTAssertTrue(backend.logs.contains { $0.message == "hello from the test" && $0.component == "engine" })
        await service.shutdown()
        let before = backend.logs.count
        Log.warn("engine", "after shutdown")
        XCTAssertEqual(backend.logs.count, before)
    }
}
