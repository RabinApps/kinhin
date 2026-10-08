import XCTest

@testable import KinhinKit
@testable import kinhin

final class BareStatusTests: XCTestCase {
    private func check(_ id: String, ok: Bool, action: String? = nil) -> SetupCheckResult {
        SetupCheckResult(id: id, title: "Check \(id)", ok: ok, detail: ok ? "fine" : "broken \(id)", action: action)
    }

    private func status(_ checks: [SetupCheckResult], ready: Bool? = nil) -> SetupStatus {
        SetupStatus(ready: ready ?? checks.allSatisfy(\.ok), checks: checks)
    }

    func testFirstFailingCheckDecidesTheNextStep() {
        let setup = status([
            check("tart", ok: true), check("config", ok: false, action: "create_config"),
            check("token", ok: false, action: "enter_account_token"),
        ])
        let step = BareStatus.nextStep(setup: setup, daemonRunning: false)
        XCTAssertEqual(step.command, "kinhin config init")
        XCTAssertEqual(step.reason, "Check config: broken config")
    }

    func testTokenAndImageStepsNameTheRightCommand() {
        let token = status([check("token", ok: false, action: "enter_account_token")])
        XCTAssertEqual(BareStatus.nextStep(setup: token, daemonRunning: false).command, "kinhin auth set")
        let image = status([check("image", ok: false, action: "prepare_image")])
        XCTAssertEqual(BareStatus.nextStep(setup: image, daemonRunning: false).command, "kinhin image prepare")
    }

    func testAFailureWithNoCommandPointsAtDoctor() {
        let setup = status([check("clt", ok: false, action: "fix_clt")])
        XCTAssertEqual(BareStatus.nextStep(setup: setup, daemonRunning: false).command, "kinhin doctor")
        let unactionable = status([check("arch", ok: false)])
        XCTAssertEqual(BareStatus.nextStep(setup: unactionable, daemonRunning: true).command, "kinhin doctor")
    }

    func testReadyMeansStartOrLookAtTheRunningFleet() {
        let ready = status([check("tart", ok: true)])
        XCTAssertEqual(BareStatus.nextStep(setup: ready, daemonRunning: false).command, "kinhin start")
        XCTAssertEqual(BareStatus.nextStep(setup: ready, daemonRunning: true).command, "kinhin status")
    }

    func testRenderShowsCountsDaemonAndOneNextStep() {
        let setup = status([check("tart", ok: true), check("token", ok: false, action: "enter_account_token")])
        let text = BareStatus.render(setup: setup, daemonRunning: false, version: "9.9.9")
        XCTAssertTrue(text.hasPrefix("kinhin 9.9.9 — "), text)
        XCTAssertTrue(text.contains("1 of 2 checks need attention"), text)
        XCTAssertTrue(text.contains("daemon   not running"), text)
        XCTAssertEqual(text.components(separatedBy: "next: ").count - 1, 1, "exactly one next step")
        XCTAssertTrue(text.contains("next: kinhin auth set"), text)
        XCTAssertTrue(text.contains("kinhin help"), text)
        for line in text.split(separator: "\n") { XCTAssertLessThanOrEqual(line.count, HelpRenderer.columns) }
    }

    func testRenderWhenReady() {
        let text = BareStatus.render(setup: status([check("tart", ok: true)]), daemonRunning: true, version: "1")
        XCTAssertTrue(text.contains("ready (1 of 1 checks)"), text)
        XCTAssertTrue(text.contains("daemon   running"), text)
        XCTAssertTrue(text.contains("next: kinhin status"), text)
    }

    func testBareIsNotTheFullHelpScreen() {
        let text = BareStatus.render(setup: status([check("tart", ok: true)]), daemonRunning: false, version: "1")
        XCTAssertLessThan(text.split(separator: "\n").count, 15)
        XCTAssertNotEqual(text, helpText())
    }
}
