import XCTest

@testable import KinhinKit
@testable import kinhin_app

@MainActor
final class DiagnosticsModelTests: XCTestCase {
    /// The minimal valid doctor report — fixtures splice extra top-level
    /// fields into it (see `report(extra:)`).
    private static let baseJSON = """
        {
          "host": {"logicalCores": 10, "memoryGB": 32, "freeDiskGB": 200, "arm64": true},
          "clt": {"state": "ok", "version": "26.0", "ok": true, "fixCommand": null, "fixHint": null},
          "tart": {"state": "healthy", "ok": true, "reason": null, "repairCommands": []},
          "container": null,
          "docker": null,
          "toolchainCache": {"root": "/tmp/c", "usable": true, "sharedWithRunners": false, "warning": false, "totalBytes": 0, "ecosystems": []},
          "auth": {"forges": [], "allGood": true},
          "checks": [],
          "ready": true,
          "capacity": null
        }
        """

    /// The base report with one optional top-level field spliced in.
    private func report(extra: String? = nil) throws -> DoctorReport {
        let json = extra.map { Self.baseJSON.dropLast() + ",\n  \($0)\n}" } ?? Self.baseJSON
        return try JSONDecoder().decode(DoctorReport.self, from: Data(json.utf8))
    }

    /// A minimal report with no `docker:` config, only the availability half.
    private func report(dockerAvailability: String) throws -> DoctorReport {
        try report(extra: "\"dockerAvailability\": \(dockerAvailability)")
    }

    private func dockerRow(_ availability: String) throws -> DiagnosticsModel.Row? {
        let model = DiagnosticsModel()
        model.render(try report(dockerAvailability: availability))
        return model.rows.first { $0.title == "Docker (Linux)" }
    }

    func testDockerRowAppearsWhenNotConfiguredButMissing() throws {
        let row = try XCTUnwrap(try dockerRow(#"{"installed": false, "supported": true, "reason": null}"#))
        XCTAssertTrue(row.detail.contains("not installed"))
        XCTAssertTrue(row.ok, "Docker is optional, so missing isn't a failure")
    }

    func testDockerRowSaysInstalledButNotEnabled() throws {
        let row = try XCTUnwrap(try dockerRow(#"{"installed": true, "supported": true, "reason": null}"#))
        XCTAssertTrue(row.detail.contains("installed — not enabled"))
    }

    func testDockerRowExplainsAnUnsupportedMac() throws {
        let row = try XCTUnwrap(try dockerRow(#"{"installed": false, "supported": false, "reason": "needs more RAM"}"#))
        XCTAssertTrue(row.detail.contains("needs more RAM"))
        XCTAssertFalse(row.ok)
    }

    func testOlderReportsWithoutAvailabilityRenderNoDockerRow() throws {
        XCTAssertNil(try dockerRow("null"))
    }

    // MARK: - Base image drift warning

    /// A healthy report plus an optional `tartBaseImage` section (nil
    /// reference = the key isn't set, so the builder omits the section).
    /// The section is encoded through JSONEncoder so the warning text needs
    /// no hand-escaping, and this doubles as a check that the report's JSON
    /// contract decodes the section.
    private func render(reference: String?, warning: String?) throws -> DiagnosticsModel.Row? {
        var extra: String?
        if let reference {
            struct Section: Encodable {
                var reference: String
                var state: String
                var ok: Bool
                var fix: String?
                var pinned: Bool
                var warning: String?
            }
            let section = Section(
                reference: reference, state: "known", ok: true, fix: nil, pinned: false, warning: warning)
            let encoded = try JSONEncoder().encode(section)
            extra = "\"tartBaseImage\": \(String(data: encoded, encoding: .utf8)!)"
        }
        let model = DiagnosticsModel()
        model.render(try report(extra: extra))
        return model.rows.first { $0.title == "Base image (macOS VMs)" }
    }

    func testMutableBaseImageRowCarriesTheSharedDriftWarning() throws {
        // The builder computes `warning` from the same
        // `TartBaseImage.mutableTagWarning` line the fleet-start log prints.
        let reference = "ghcr.io/cirruslabs/macos-sequoia-base:latest"
        let warning = try XCTUnwrap(TartBaseImage.mutableTagWarning(for: reference))
        let row = try XCTUnwrap(try render(reference: reference, warning: warning))
        XCTAssertEqual(row.warning, warning)
        XCTAssertTrue(row.ok, "a usable base image stays green — the caveat is advisory")
        XCTAssertTrue(row.detail.contains(reference))
        XCTAssertTrue(warning.contains("pin a digest"), "the shared wording survived")
    }

    func testPinnedBaseImageRendersNoRow() throws {
        let reference = "ghcr.io/cirruslabs/macos-sequoia-base@sha256:\(String(repeating: "a", count: 64))"
        XCTAssertNil(
            try render(reference: reference, warning: nil),
            "pinned = reproducible = nothing to warn about")
    }

    func testAbsentBaseImageRendersNoRow() throws {
        XCTAssertNil(try render(reference: nil, warning: nil), "no base_image: key → no row")
    }

    // MARK: - Image disk usage row

    /// The base report with the given `imageTotalGB` object, rendered.
    private func render(imageTotalGB: String) throws -> DiagnosticsModel.Row? {
        let model = DiagnosticsModel()
        model.render(try report(extra: "\"imageTotalGB\": \(imageTotalGB)"))
        return model.rows.first { $0.title == "Image disk usage" }
    }

    /// The breakdown the doctor report carries, rendered as the same line the
    /// human doctor prints — one row per Mac, all runtimes with sizes.
    func testImageDiskUsageRowShowsEveryRuntimeTotal() throws {
        let row = try XCTUnwrap(render(imageTotalGB: #"{"tart": 52, "container": 4, "docker": 65}"#))
        XCTAssertEqual(row.detail, "tart 52 GB · container 4 GB · docker 65 GB")
        XCTAssertTrue(row.ok, "disk usage is informational — bloat is pruned, not a fault")
    }

    /// A runtime without a measured size stays off the row, and a measured
    /// sub-GB total reads "<1 GB", never "0 GB".
    func testImageDiskUsageRowCountsOnlyRuntimesWithSizes() throws {
        let row = try XCTUnwrap(render(imageTotalGB: #"{"docker": 0, "tart": 40}"#))
        XCTAssertEqual(row.detail, "tart 40 GB · docker <1 GB", "container reported no sizes → no mention")
    }

    /// Reports from before the breakdown (or with nothing measured) gain no row.
    func testNoImageDiskUsageRowWithoutTheField() throws {
        let model = DiagnosticsModel()
        model.render(try report())
        XCTAssertNil(model.rows.first { $0.title == "Image disk usage" })
    }

    // MARK: - Unused images row (the prune suggestion)

    /// The base report with the given `imagePrune` object, rendered.
    private func render(imagePrune: String) throws -> DiagnosticsModel.Row? {
        let model = DiagnosticsModel()
        model.render(try report(extra: "\"imagePrune\": \(imagePrune)"))
        return model.rows.first { $0.title == "Unused images" }
    }

    /// The suggestion, worded exactly like the doctor's `prune:` row — same
    /// shared line, so the two surfaces cannot drift.
    func testUnusedImagesRowSuggestsPrune() throws {
        let row = try XCTUnwrap(
            render(imagePrune: #"{"count": 62, "reclaimGB": 68, "command": "kinhin image prune"}"#))
        XCTAssertEqual(row.detail, "62 unused image(s) (~68 GB) — review with: kinhin image prune")
        XCTAssertTrue(row.ok, "advice, not a fault — it never blocks readiness")
    }

    func testNoUnusedImagesRowWithoutASuggestion() throws {
        let model = DiagnosticsModel()
        model.render(try report())
        XCTAssertNil(model.rows.first { $0.title == "Unused images" })
    }

    // MARK: - Disk pressure row

    /// The base report with the given `diskPressure` object, rendered.
    private func render(diskPressure: String) throws -> DiagnosticsModel.Row? {
        let model = DiagnosticsModel()
        model.render(try report(extra: "\"diskPressure\": \(diskPressure)"))
        return model.rows.first { $0.title == "Disk pressure" }
    }

    /// The engine's guard, worded like the doctor's WARNING line — and not
    /// ok: the next spawn is held until disk frees.
    func testDiskPressureRowWarnsBeforeTheFleetHoldsSpawns() throws {
        let row = try XCTUnwrap(
            render(
                diskPressure:
                    #"{"freeGB": 40, "runtime": "tart", "instanceDiskGB": 50, "reserveGB": 10}"#))
        XCTAssertEqual(
            row.detail,
            "40 GB free, a new tart instance needs 50 GB + 10 GB reserve — the fleet holds spawns")
        XCTAssertFalse(row.ok, "the next spawn is held until disk frees")
    }

    func testNoDiskPressureRowWhenThereIsHeadroom() throws {
        let model = DiagnosticsModel()
        model.render(try report())
        XCTAssertNil(model.rows.first { $0.title == "Disk pressure" })
    }
}
