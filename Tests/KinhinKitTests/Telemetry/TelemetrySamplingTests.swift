import Foundation
import OpenTelemetryApi
import XCTest

@testable import KinhinKit

/// `telemetry.sampling_ratio` and `OTEL_TRACES_SAMPLER[_ARG]`: how they resolve, and what a dropped trace does.
final class TelemetrySamplingTests: XCTestCase {
    private let host = TelemetryHostInfo(hostName: "h", architecture: "arm64", osVersion: "26.0.0")

    private func resolve(ratio: Double = 1, env: [String: String] = [:]) -> TelemetrySettings {
        TelemetryResolver.resolve(
            KinhinConfig.TelemetryConfig(enabled: true, samplingRatio: ratio), environment: env, host: host)
    }

    // MARK: - Resolution

    func testConfigRatioPicksTheSampler() {
        XCTAssertEqual(resolve(ratio: 1).sampler, .alwaysOn)
        XCTAssertEqual(resolve(ratio: 0).sampler, .alwaysOff)
        XCTAssertEqual(resolve(ratio: 0.25).sampler, .parentBasedTraceIDRatio(0.25))
        XCTAssertEqual(resolve().sampler.ratio, 1, "records everything by default")
    }

    func testEnvironmentSamplerOverridesConfig() {
        XCTAssertEqual(resolve(ratio: 0.5, env: ["OTEL_TRACES_SAMPLER": "always_off"]).sampler, .alwaysOff)
        XCTAssertEqual(resolve(ratio: 0.5, env: ["OTEL_TRACES_SAMPLER": "ALWAYS_ON"]).sampler, .alwaysOn)
        let ratio = resolve(env: ["OTEL_TRACES_SAMPLER": "traceidratio", "OTEL_TRACES_SAMPLER_ARG": "0.1"])
        XCTAssertEqual(ratio.sampler, .traceIDRatio(0.1))
        let parent = resolve(env: ["OTEL_TRACES_SAMPLER": "parentbased_traceidratio", "OTEL_TRACES_SAMPLER_ARG": "0.2"])
        XCTAssertEqual(parent.sampler, .parentBasedTraceIDRatio(0.2))
        XCTAssertTrue(parent.warnings.isEmpty, "\(parent.warnings)")
    }

    func testUnusableSamplerValuesAreIgnoredWithAWarning() {
        for env in [
            ["OTEL_TRACES_SAMPLER": "sometimes"],
            ["OTEL_TRACES_SAMPLER": "traceidratio"],
            ["OTEL_TRACES_SAMPLER": "traceidratio", "OTEL_TRACES_SAMPLER_ARG": "2"],
            ["OTEL_TRACES_SAMPLER": "parentbased_traceidratio", "OTEL_TRACES_SAMPLER_ARG": "lots"],
        ] {
            let settings = resolve(ratio: 0.5, env: env)
            XCTAssertEqual(settings.sampler, .parentBasedTraceIDRatio(0.5), "\(env): falls back to the config")
            XCTAssertEqual(settings.warnings.count, 1, "\(env): \(settings.warnings)")
        }
    }

    func testRatioIsReportedInTheDescriptionAndStatus() {
        let settings = resolve(ratio: 0.25)
        XCTAssertTrue(settings.description.contains("sampler=parentbased_traceidratio(0.25)"), settings.description)
        let status = TelemetryStatus(settings: settings, prometheusPort: 0, startedAt: Date())
        XCTAssertEqual(status.samplingRatio, 0.25)
        XCTAssertEqual(status.persist, false)
    }

    // MARK: - The SDK pipeline

    private func backend(ratio: Double) throws -> OTelBackend {
        var settings = resolve(ratio: ratio)
        settings.signals = [.traces]
        // Nothing listens here; the spans are dropped or fail to export, and the test only looks at the handles.
        settings.endpoints = [.traces: URL(string: "http://127.0.0.1:9/v1/traces")!]
        return try OTelBackend(settings: settings)
    }

    func testRecordedRootGivesRealChildren() async throws {
        let backend = try backend(ratio: 1)
        defer { Task { await backend.shutdown() } }
        let root = backend.startSpan("kinhin.job", start: nil, attributes: [:])
        let context = try XCTUnwrap(root.context)
        let child = root.startChild("provision", start: nil, attributes: [:])
        XCTAssertEqual(child.context?.traceID, context.traceID, "a child shares its root's trace")
        child.end(at: nil, error: nil)
        root.end(at: nil, error: nil)
    }

    func testDroppedRootMakesTheWholeTraceANoop() async throws {
        let backend = try backend(ratio: 0)
        defer { Task { await backend.shutdown() } }
        let root = backend.startSpan("kinhin.job", start: nil, attributes: ["kinhin.pool": .string("tart")])
        XCTAssertNil(root.context, "a dropped trace has no ids to correlate logs with")
        let child = root.startChild("provision", start: Date(), attributes: [:])
        XCTAssertNil(child.context, "a child of a dropped root must not become a root the sampler decides afresh")
        child.setAttributes(["a": .int(1)])
        child.startChild("grandchild", start: nil, attributes: [:]).end(at: nil, error: "boom")
        child.end(at: Date(), error: nil)
        root.setAttributes(["b": .bool(true)])
        root.end(at: nil, error: "boom")
    }

    func testRatioKeepsRoughlyThatShareOfTraces() async throws {
        let backend = try backend(ratio: 0.5)
        defer { Task { await backend.shutdown() } }
        var kept = 0
        for _ in 0..<400 {
            let root = backend.startSpan("kinhin.job", start: nil, attributes: [:])
            if root.context != nil { kept += 1 }
            root.end(at: nil, error: nil)
        }
        XCTAssertTrue((120...280).contains(kept), "kept \(kept) of 400 at 0.5")
    }
}
