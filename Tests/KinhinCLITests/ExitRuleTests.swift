import XCTest

@testable import KinhinKit
@testable import kinhin

/// The one exit-code rule: 0 healthy, 1 needs attention, 2 usage error. The
/// commands that report a state all derive "healthy" from their document and
/// pass it through `ExitRule`.
final class ExitRuleTests: XCTestCase {
    func testTheRuleIsZeroWhenHealthyAndOneWhenNot() {
        XCTAssertNil(ExitRule.code(healthy: true), "healthy exits 0")
        XCTAssertEqual(ExitRule.code(healthy: false), .needsAttention)
        XCTAssertEqual(CLIExit.needsAttention.rawValue, 1)
        XCTAssertEqual(CLIExit.usage.rawValue, 2)
    }

    func testStatusIsHealthyOnlyWhenADaemonAnswers() {
        XCTAssertFalse(RunCommands.isHealthy(StatusDocument(daemonRunning: false, fleet: nil)))
        XCTAssertTrue(RunCommands.isHealthy(StatusDocument(daemonRunning: true, fleet: FleetStatus())))
        // A paused fleet is a deliberate state, not an alarm.
        var paused = FleetStatus()
        paused.paused = true
        XCTAssertTrue(RunCommands.isHealthy(StatusDocument(daemonRunning: true, fleet: paused)))
    }

    func testNoDaemonMessagesTellStopFromPauseResume() {
        XCTAssertTrue(RunCommands.noDaemonMessage(for: .stop).contains("nothing to stop"))
        XCTAssertTrue(RunCommands.noDaemonMessage(for: .pause).contains("pause/resume"))
        XCTAssertEqual(RunCommands.noDaemonMessage(for: .pause), RunCommands.noDaemonMessage(for: .resume))
    }

    func testControlResultJSONHasActionOkAndMessage() throws {
        let result = RunCommands.ControlResult(action: "stop", ok: false, message: "no daemon running")
        let decoded = try JSONDecoder().decode(
            RunCommands.ControlResult.self, from: try CLIJSON.data(result))
        XCTAssertEqual(decoded, result)
        let text = try CLIJSON.string(result)
        XCTAssertTrue(text.contains("\"ok\" : false"), text)
    }

    func testErrorsUnderJSONCarryTheSameCodeTheProcessExitsWith() throws {
        let error = CLIError("unknown option '--ys'", exit: .usage)
        let out = ErrorReporter.render(error.message, code: CLIExit(error), json: true)
        let document = try JSONDecoder().decode(ErrorDocument.self, from: Data(try XCTUnwrap(out.stdout).utf8))
        XCTAssertEqual(document.code, 2)
    }
}
