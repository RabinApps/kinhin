import XCTest

@testable import kinhin

final class JSONOutputTests: XCTestCase {
    private struct Sample: Codable, Equatable {
        var zeta: Int
        var alpha: String
        var when: Date
    }

    func testTheOneEncoderIsPrettyAndSorted() throws {
        let text = try CLIJSON.string(Sample(zeta: 1, alpha: "a", when: Date(timeIntervalSince1970: 0)))
        let alpha = try XCTUnwrap(text.range(of: "\"alpha\""))
        let zeta = try XCTUnwrap(text.range(of: "\"zeta\""))
        XCTAssertLessThan(alpha.lowerBound, zeta.lowerBound, "keys are sorted")
        XCTAssertTrue(text.contains("\n"), "pretty-printed")
    }

    func testDatesAreNumbersUnlessISOIsRequested() throws {
        let sample = Sample(zeta: 1, alpha: "a", when: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(try CLIJSON.string(sample).contains("-978307200"), "default keeps the existing contract")
        XCTAssertTrue(try CLIJSON.string(sample, dates: .iso8601).contains("1970-01-01T00:00:00Z"))
    }

    func testFailuresAreProseOnStderrByDefault() {
        let out = ErrorReporter.render("boom", code: .runtime, json: false)
        XCTAssertNil(out.stdout)
        XCTAssertEqual(out.stderr, "kinhin: boom")
    }

    func testFailuresUnderJSONAreADocumentOnStdout() throws {
        let out = ErrorReporter.render("bad flag", code: .usage, json: true)
        XCTAssertNil(out.stderr)
        let document = try JSONDecoder().decode(ErrorDocument.self, from: Data(try XCTUnwrap(out.stdout).utf8))
        XCTAssertEqual(document, ErrorDocument(error: "bad flag", code: 2))
    }

    func testTheJSONSwitchRoundTrips() {
        ErrorReporter.useJSON(true)
        XCTAssertTrue(ErrorReporter.isJSON)
        ErrorReporter.useJSON(false)
        XCTAssertFalse(ErrorReporter.isJSON)
    }
}
