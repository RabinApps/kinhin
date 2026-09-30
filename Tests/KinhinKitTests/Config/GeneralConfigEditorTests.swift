import XCTest

@testable import KinhinKit

final class GeneralConfigEditorTests: XCTestCase {
    private var dir: URL!
    private var file: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gce-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("config.yaml")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String) throws {
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private static let sample = """
        # kinhin configuration
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: ["self-hosted", "macos"]
        min_runners: 0
        max_runners: 2
        poll_interval: 20
        vm:
          cpu: 4          # per-VM cores
          memory_gb: 8
          ephemeral: true
        image: "tahoe-base"
        reserve:
          cpu: 2
          memory_gb: 4

        # Optional section below
        """

    // MARK: Snapshot

    func testSnapshotReadsAllGeneralKeys() throws {
        let snap = try GeneralConfigEditor.snapshot(from: Self.sample)
        XCTAssertEqual(snap.labels, ["self-hosted", "macos"])
        XCTAssertEqual(snap.minRunners, 0)
        XCTAssertEqual(snap.maxRunners, 2)
        XCTAssertEqual(snap.pollInterval, 20)
        XCTAssertEqual(snap.autoResume, false)
        XCTAssertEqual(snap.vmCPU, 4)
        XCTAssertEqual(snap.vmMemoryGB, 8)
        XCTAssertEqual(snap.vmEphemeral, true)
        XCTAssertEqual(snap.image, "tahoe-base")
        XCTAssertEqual(snap.reserveCPU, 2)
        XCTAssertEqual(snap.reserveMemoryGB, 4)
        XCTAssertNil(snap.container)
        XCTAssertNil(snap.docker)
    }

    func testSnapshotFillsDefaultsForMissingKeys() throws {
        let snap = try GeneralConfigEditor.snapshot(
            from: "accounts:\n  - name: github\n    forge: github\n    scope: \"a/b\"\n")
        XCTAssertEqual(snap.labels, KinhinConfig.default.labels)
        XCTAssertEqual(snap.pollInterval, KinhinConfig.default.pollInterval)
        XCTAssertEqual(snap.vmCPU, KinhinConfig.default.vm.cpuCount)
    }

    func testSnapshotRejectsNonMappingYAML() {
        XCTAssertThrowsError(try GeneralConfigEditor.snapshot(from: "- just\n- a\n- list\n"))
    }

    func testSnapshotNamesAWrongTypedKeyInsteadOfShowingDefaults() {
        // A mistyped value must not render as the default (the form would
        // then show a number the file does not contain).
        let yaml = "labels: [\"ci\"]\nvm:\n  cpu: four\n"
        XCTAssertThrowsError(try GeneralConfigEditor.snapshot(from: yaml)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("vm.cpu"), message)
        }
    }

    // MARK: Targeted surgery

    func testScalarEditPreservesCommentsAndNeighbors() throws {
        try write(Self.sample)
        _ = try GeneralConfigEditor.apply(.minRunners(1), to: file)
        let updated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(updated.contains("min_runners: 1"))
        XCTAssertTrue(updated.contains("# kinhin configuration"), "header comment survives")
        XCTAssertTrue(updated.contains("# per-VM cores"), "trailing comment on untouched key survives")
        XCTAssertTrue(updated.contains("# Optional section below"))
        XCTAssertTrue(updated.contains("image: \"tahoe-base\""))
    }

    func testScalarEditsInsideVmAndReserveSections() throws {
        try write(Self.sample)
        _ = try GeneralConfigEditor.apply(.vmCPU(6), to: file)
        _ = try GeneralConfigEditor.apply(.vmMemoryGB(12), to: file)
        _ = try GeneralConfigEditor.apply(.reserveCPU(1), to: file)
        let updated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(updated.contains("cpu: 6"))
        XCTAssertTrue(updated.contains("memory_gb: 12"))
        XCTAssertTrue(updated.contains("memory_gb: 4"), "reserve section untouched")
        // Parse the result to confirm the values landed in the right places.
        let snap = try GeneralConfigEditor.snapshot(from: updated)
        XCTAssertEqual(snap.vmCPU, 6)
        XCTAssertEqual(snap.vmMemoryGB, 12)
        XCTAssertEqual(snap.reserveCPU, 1)
        XCTAssertEqual(snap.reserveMemoryGB, 4)
    }

    func testBooleanEdit() throws {
        try write(Self.sample)
        _ = try GeneralConfigEditor.apply(.vmEphemeral(false), to: file)
        let snap = try GeneralConfigEditor.snapshot(from: try String(contentsOf: file, encoding: .utf8))
        XCTAssertEqual(snap.vmEphemeral, false)
    }

    func testAutoResumeEdit() throws {
        try write(Self.sample)
        _ = try GeneralConfigEditor.apply(.autoResume(true), to: file)
        let updated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(updated.contains("auto_resume: true"))
        XCTAssertEqual(try GeneralConfigEditor.snapshot(from: updated).autoResume, true)
    }

    func testLabelsRewriteKeepsFlowStyle() throws {
        try write(Self.sample)
        _ = try GeneralConfigEditor.apply(.labels(["ci", "arm64", "gpu"]), to: file)
        let updated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(updated.contains("labels: [\"ci\", \"arm64\", \"gpu\"]"))
    }

    func testCreatingMissingSectionKey() throws {
        // A full valid config missing only the vm: section.
        try write("accounts:\n  - name: github\n    forge: github\n    scope: \"acme/x\"\nlabels: [\"ci\"]\n")
        _ = try GeneralConfigEditor.apply(.vmCPU(8), to: file)
        let updated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(updated.contains("vm:\n  cpu: 8"))
        // The result must parse and round-trip.
        XCTAssertEqual(try GeneralConfigEditor.snapshot(from: updated).vmCPU, 8)
    }

    // MARK: Section toggles

    func testAccountsAddAndRemovePreserveTheRest() throws {
        try write(Self.sample)
        _ = try AccountsConfigEditor.add(
            AccountConfig(name: "gitea", forge: .gitea, scope: "acme", instance: "https://gitea.acme.dev"), to: file)
        let updated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(updated.contains("name: \"gitea\""), updated)
        XCTAssertTrue(updated.contains("# Optional section below"), "comments survive accounts insert")
        var accounts = try AccountsConfigEditor.accounts(at: file)
        XCTAssertEqual(accounts.map(\.name), ["github", "gitea"])

        _ = try AccountsConfigEditor.remove(name: "gitea", at: file)
        accounts = try AccountsConfigEditor.accounts(at: file)
        XCTAssertEqual(accounts.map(\.name), ["github"])
        XCTAssertTrue(
            try String(contentsOf: file, encoding: .utf8).contains("image: \"tahoe-base\""),
            "the rest of the file is untouched")
    }

    func testContainerAndDockerToggles() throws {
        try write(Self.sample)
        _ = try GeneralConfigEditor.apply(.container(.init(image: "kinhin-ci-linux", cpus: 2, memoryGB: 4)), to: file)
        _ = try GeneralConfigEditor.apply(
            .docker(.init(image: "docker-ci", cpus: 1, memoryGB: 2, maxSlots: 4)), to: file)
        let updated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(updated.contains("container:"))
        XCTAssertTrue(updated.contains("docker:"))
        let snap = try GeneralConfigEditor.snapshot(from: updated)
        XCTAssertEqual(snap.container?.image, "kinhin-ci-linux")
        XCTAssertEqual(snap.docker?.maxSlots, 4)
    }

    func testIdempotentToggleKeepsSingleSection() throws {
        try write(Self.sample)
        _ = try GeneralConfigEditor.apply(.docker(.init(image: "a", cpus: 1, memoryGB: 2, maxSlots: 2)), to: file)
        _ = try GeneralConfigEditor.apply(.docker(.init(image: "b", cpus: 2, memoryGB: 3, maxSlots: 3)), to: file)
        let updated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(updated.components(separatedBy: "docker:").count - 1, 1, "upsert, never duplicate")
        XCTAssertEqual(try GeneralConfigEditor.snapshot(from: updated).docker?.image, "b")
    }

    // MARK: Validation gate

    func testInvalidEditNeverWrites() throws {
        try write(Self.sample)
        let before = try Data(contentsOf: file)
        // Empty labels fail ConfigLoader validation → nothing lands.
        XCTAssertThrowsError(try GeneralConfigEditor.apply(.labels([]), to: file))
        let after = try Data(contentsOf: file)
        XCTAssertEqual(before, after, "the file is byte-identical after a rejected edit")
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(
            try GeneralConfigEditor.apply(.pollInterval(30), to: dir.appendingPathComponent("nope.yaml")))
    }
}
