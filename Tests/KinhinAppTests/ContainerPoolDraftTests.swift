import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The container pool sheet's fields: what they read from a pool, what they write, what they refuse, and the
/// placeholders that show a blank field's inherited value.
@MainActor
final class ContainerPoolDraftTests: XCTestCase {
    private let full = ContainerPoolsConfigEditor.Pool(
        name: "big", image: "kinhin-ci-big", baseImage: "debian:12", cpus: 4, memoryGB: 12, labels: ["linux", "big"],
        fleetLabels: false, minIdle: 1, docker: true, flags: ["--shm-size", "2g", "--env=A B"], max: 2)

    func testAPoolRoundTripsThroughTheFields() {
        let draft = ContainerPoolDraft(pool: full)
        XCTAssertEqual(draft.name, "big")
        XCTAssertEqual(draft.labels, "linux, big")
        XCTAssertEqual(draft.cpus, "4")
        XCTAssertEqual(draft.docker, .on)
        XCTAssertEqual(draft.flags, "--shm-size\n2g\n--env=A B", "one argument per line, spaces kept")
        XCTAssertNil(draft.problem)
        XCTAssertEqual(draft.pool(keeping: full), full, "fleet_labels comes from the pool being edited")
    }

    func testEditingAnAmd64PoolKeepsItsPlatform() {
        var amd64 = full
        amd64.platform = "linux/amd64"
        var draft = ContainerPoolDraft(pool: amd64)
        draft.cpus = "6"
        XCTAssertEqual(draft.pool(keeping: amd64).platform, "linux/amd64", "the sheet does not show it, so it stays")
        XCTAssertNil(draft.pool(keeping: nil).platform, "a new pool inherits the section's platform")
    }

    func testBlankFieldsLeaveTheirKeysOut() {
        var draft = ContainerPoolDraft()
        draft.name = " small "
        draft.cpus = "  "
        XCTAssertNil(draft.problem)
        XCTAssertEqual(draft.pool(keeping: nil), .init(name: "small"), "a blank field inherits the section's value")
    }

    func testDockerHasThreeChoices() {
        var draft = ContainerPoolDraft()
        draft.name = "a"
        XCTAssertNil(draft.pool(keeping: nil).docker)
        draft.docker = .off
        XCTAssertEqual(draft.pool(keeping: nil).docker, false)
        draft.docker = .on
        XCTAssertEqual(draft.pool(keeping: nil).docker, true)
        XCTAssertEqual(ContainerPoolDraft(pool: .init(name: "a", docker: false)).docker, .off)
        XCTAssertEqual(ContainerPoolDraft(pool: .init(name: "a")).docker, .inherit)
    }

    func testLabelsSplitOnCommasAndSpacesAndFlagsOnLines() {
        var draft = ContainerPoolDraft()
        draft.name = "a"
        draft.labels = "linux,big  gpu"
        draft.flags = "--init\n\n  --shm-size  \n2g\n"
        let pool = draft.pool(keeping: nil)
        XCTAssertEqual(pool.labels, ["linux", "big", "gpu"])
        XCTAssertEqual(pool.flags, ["--init", "--shm-size", "2g"], "blank lines dropped, each line trimmed")
    }

    func testProblemsComeOneAtATimeInFieldOrder() {
        var draft = ContainerPoolDraft()
        XCTAssertEqual(draft.problem, "Enter a pool name.")
        draft.name = "Big"
        XCTAssertTrue(draft.problem?.hasPrefix("A pool name is lowercase") == true, draft.problem ?? "")
        draft.name = String(repeating: "a", count: 33)
        XCTAssertNotNil(draft.problem, "longer than 32 characters")
        draft.name = "big"
        draft.cpus = "0"
        XCTAssertEqual(draft.problem, "CPUs must be a whole number, 1 or more.")
        draft.cpus = "2"
        draft.memoryGB = "lots"
        XCTAssertEqual(draft.problem, "Memory must be a whole number of GB, 1 or more.")
        draft.memoryGB = ""
        draft.max = "0"
        XCTAssertEqual(draft.problem, "Max runners must be a whole number, 1 or more.")
        draft.max = "3"
        draft.minIdle = "-1"
        XCTAssertEqual(draft.problem, "Idle runners must be a whole number, 0 or more.")
        draft.minIdle = "0"
        XCTAssertNil(draft.problem)
    }

    func testPlaceholdersShowWhatABlankFieldInherits() {
        XCTAssertEqual(ContainerPoolSheet.inherited("4"), "inherits 4")
        XCTAssertEqual(ContainerPoolSheet.labelsPlaceholder(["linux"]), "inherits linux")
        XCTAssertEqual(ContainerPoolSheet.labelsPlaceholder(nil), "e.g. linux, big")
        XCTAssertEqual(ContainerPoolSheet.imagePlaceholder("kinhin-ci-linux"), "inherits kinhin-ci-linux")
        XCTAssertEqual(ContainerPoolSheet.imagePlaceholder(""), "required (container: names no image)")
        XCTAssertEqual(ContainerPoolSheet.dockerDefault(true), "Default (on)")
        XCTAssertEqual(ContainerPoolSheet.noLimit, "no limit")
    }
}
