import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// `FleetStatus.imageNotice` ("baking image for…") shows on the Fleet tab and
/// in Diagnostics when set, and nowhere when nil.
@MainActor final class ImageNoticeTests: XCTestCase {
    private let notice = "baking image for acme/api (go@1.22.5), using base meanwhile"

    func testFleetModelExposesTheNoticeOnlyWhenSet() {
        let controller = FleetController()
        let model = FleetModel(controller: controller)
        XCTAssertNil(model.imageNotice)
        controller.status = FleetStatus(running: true)
        XCTAssertNil(model.imageNotice)
        var status = FleetStatus(running: true)
        status.imageNotice = notice
        controller.status = status
        XCTAssertEqual(model.imageNotice, notice)
    }

    func testDiagnosticsShowsAnInformationalRowWhenSet() throws {
        let json = """
            {
              "host": {"logicalCores": 10, "memoryGB": 32, "freeDiskGB": 200, "arm64": true},
              "clt": {"state": "ok", "version": "26.0", "ok": true, "fixCommand": null, "fixHint": null},
              "tart": {"state": "healthy", "ok": true, "reason": null, "repairCommands": []},
              "container": null, "docker": null,
              "toolchainCache": {"root": "/tmp/c", "usable": true, "sharedWithRunners": false, "warning": false, "totalBytes": 0, "ecosystems": []},
              "auth": {"forges": [], "allGood": true}, "checks": [], "ready": true, "capacity": null
            }
            """
        let report = try JSONDecoder().decode(DoctorReport.self, from: Data(json.utf8))
        let model = DiagnosticsModel()
        model.render(report)
        XCTAssertNil(model.rows.first { $0.title == "Project images" })

        model.fleetImageNotice = { [notice] in notice }
        model.render(report)
        let row = try XCTUnwrap(model.rows.first { $0.title == "Project images" })
        XCTAssertEqual(row.detail, notice)
        XCTAssertTrue(row.ok, "a bake in progress is not an error")
    }
}
