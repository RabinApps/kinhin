import XCTest

@testable import KinhinKit

/// The app's Telemetry card edits `telemetry:` through this: one key's line changes, everything else (comments, other
/// keys, other sections) survives, and an edit that would not validate is never written.
final class TelemetryConfigEditorTests: XCTestCase {
    private let base = """
        # kinhin configuration
        accounts:
          - name: github
            forge: github
            scope: "acme/ios-app"

        labels: ["self-hosted", "macos"]
        """

    private func tempConfig(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-telemetry-\(UUID().uuidString).yaml")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func edit(_ field: TelemetryConfigEditor.Field, _ yaml: String) throws -> (text: String, url: URL) {
        let url = try tempConfig(yaml)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let text = try TelemetryConfigEditor.apply(field, to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
        return (text, url)
    }

    // MARK: - Reading

    func testNoSectionReadsAsOff() throws {
        XCTAssertEqual(try TelemetryConfigEditor.snapshot(in: base), .init(enabled: false, prometheusListen: nil))
        XCTAssertEqual(try TelemetryConfigEditor.snapshot(in: "  \n"), .init(enabled: false, prometheusListen: nil))
    }

    func testReadsBothKeys() throws {
        let yaml = base + "\ntelemetry:\n  enabled: true\n  prometheus_listen: \"127.0.0.1:9464\"\n"
        XCTAssertEqual(
            try TelemetryConfigEditor.snapshot(in: yaml), .init(enabled: true, prometheusListen: "127.0.0.1:9464"))
    }

    func testMistypedEnabledThrowsInsteadOfReadingOff() {
        XCTAssertThrowsError(try TelemetryConfigEditor.snapshot(in: "telemetry:\n  enabled: [1]\n"))
    }

    // MARK: - enabled

    func testEnableAppendsTheSectionWhenAbsent() throws {
        let (text, url) = try edit(.enabled(true), base)
        XCTAssertTrue(text.hasSuffix("telemetry:\n  enabled: true"), text)
        XCTAssertTrue(text.contains("# kinhin configuration"))
        XCTAssertTrue(try ConfigLoader.load(from: url).telemetry.enabled)
    }

    func testDisableWithoutASectionChangesNothing() throws {
        XCTAssertEqual(try edit(.enabled(false), base).text, base)
    }

    func testFlipsEnabledInPlaceKeepingNeighboursAndComments() throws {
        let yaml = """
            \(base)

            # where it goes
            telemetry:
              enabled: false   # turn me on
              endpoint: http://localhost:4318
              signals: [metrics]

            max_runners: 2
            """
        let (text, url) = try edit(.enabled(true), yaml)
        XCTAssertEqual(
            text, yaml.replacingOccurrences(of: "enabled: false   # turn me on", with: "enabled: true # turn me on"))
        let config = try ConfigLoader.load(from: url)
        XCTAssertTrue(config.telemetry.enabled)
        XCTAssertEqual(config.telemetry.endpoint, "http://localhost:4318")
        XCTAssertEqual(config.maxRunners, 2)
    }

    func testInsertsEnabledWhenTheSectionLacksIt() throws {
        let yaml = base + "\ntelemetry:\n  endpoint: http://localhost:4318\n\nmax_runners: 2\n"
        let (text, _) = try edit(.enabled(true), yaml)
        XCTAssertTrue(
            text.contains("telemetry:\n  enabled: true\n  endpoint: http://localhost:4318\n\nmax_runners: 2"), text)
    }

    func testEmptySectionHeaderGetsAChild() throws {
        let yaml = base + "\ntelemetry:  # off for now\n"
        let (text, url) = try edit(.enabled(true), yaml)
        XCTAssertTrue(text.contains("telemetry:  # off for now\n  enabled: true"), text)
        XCTAssertTrue(try ConfigLoader.load(from: url).telemetry.enabled)
    }

    func testFollowsTheSectionsOwnIndent() throws {
        let yaml = base + "\ntelemetry:\n    enabled: false\n    signals: [metrics]\n"
        XCTAssertTrue(try edit(.enabled(true), yaml).text.contains("telemetry:\n    enabled: true\n    signals"))
    }

    func testDoesNotConfuseANestedOrSimilarKey() throws {
        let yaml = base + "\ntelemetry:\n  resource_attributes:\n    enabled: nope\n  signals: [metrics]\n"
        let (text, url) = try edit(.enabled(true), yaml)
        XCTAssertTrue(text.contains("    enabled: nope"), "the nested attribute is left alone")
        XCTAssertTrue(try ConfigLoader.load(from: url).telemetry.enabled)
    }

    func testFlowStyleSectionIsRefusedAndNotWritten() throws {
        let yaml = base + "\ntelemetry: {enabled: false}\n"
        let url = try tempConfig(yaml)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try TelemetryConfigEditor.apply(.enabled(true), to: url)) { error in
            guard case ConfigEditError.unsupported = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), yaml)
    }

    func testMissingFileIsNotFound() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).yaml")
        XCTAssertThrowsError(try TelemetryConfigEditor.apply(.enabled(true), to: url)) { error in
            guard case ConfigEditError.notFound = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: - prometheus_listen

    func testSetsAndRemovesTheListenAddress() throws {
        let yaml = base + "\ntelemetry:\n  enabled: true\n  signals: [metrics]\n"
        let (set, url) = try edit(.prometheusListen(" 127.0.0.1:9464 "), yaml)
        XCTAssertTrue(set.contains("telemetry:\n  prometheus_listen: \"127.0.0.1:9464\"\n  enabled: true"), set)
        XCTAssertEqual(try ConfigLoader.load(from: url).telemetry.prometheusListen, "127.0.0.1:9464")

        let removed = try TelemetryConfigEditor.apply(.prometheusListen(nil), to: url)
        XCTAssertEqual(removed, yaml)
        XCTAssertNil(try ConfigLoader.load(from: url).telemetry.prometheusListen)
    }

    func testBareNumberPortIsQuotedSoItStaysAString() throws {
        let (text, url) = try edit(.prometheusListen("9464"), base + "\ntelemetry:\n  enabled: true\n")
        XCTAssertTrue(text.contains("prometheus_listen: \"9464\""), text)
        XCTAssertEqual(try ConfigLoader.load(from: url).telemetry.prometheusListen, "9464")
    }

    func testInvalidAddressIsRejectedAndNothingIsWritten() throws {
        let yaml = base + "\ntelemetry:\n  enabled: true\n"
        let url = try tempConfig(yaml)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try TelemetryConfigEditor.apply(.prometheusListen("not an address"), to: url)) { error in
            guard case ConfigEditError.validation(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("prometheus_listen"), why)
        }
        XCTAssertThrowsError(try TelemetryConfigEditor.apply(.prometheusListen("  "), to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), yaml)
    }

    func testListenerWithoutMetricsSignalIsRejected() throws {
        let yaml = base + "\ntelemetry:\n  enabled: true\n  signals: [traces]\n"
        let url = try tempConfig(yaml)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try TelemetryConfigEditor.apply(.prometheusListen("9464"), to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), yaml)
    }
}
