import XCTest

@testable import KinhinKit

/// The scalar `min_idle` family through the editors: each value lands in its own key, comments survive, and a
/// combination the loader rejects never reaches the disk.
final class MinIdleEditorRoundTripTests: XCTestCase {
    private var dir: URL!
    private var file: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mie-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("config.yaml")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private static let sample = """
        # kinhin configuration
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: ["self-hosted", "macos"]
        max_runners: 4   # fleet cap
        warm_max_age_minutes: 60  # warm VM lifetime
        reserve:
          cpu: 2   # host cores kept back
          memory_gb: 4
        container:
          # the Linux pool
          image: "kinhin-ci-linux"
          cpus: 4
          memory_gb: 8
        docker:
          image: "kinhin-ci-linux"
          cpus: 2
          memory_gb: 4
          max_slots: 4   # docker slots
        images:
          - name: "xcode"
            labels: ["xcode"]
            min_idle: 1
        """

    private func seed() throws {
        try Self.sample.write(to: file, atomically: true, encoding: .utf8)
    }

    private func text() throws -> String { try String(contentsOf: file, encoding: .utf8) }

    func testSnapshotReadsTheNewFields() throws {
        try seed()
        let snapshot = try GeneralConfigEditor.snapshot(from: text())
        XCTAssertEqual(snapshot.imageMinIdle, 0)
        XCTAssertEqual(snapshot.warmMaxAgeMinutes, 60)
        XCTAssertEqual(snapshot.reserveDiskGB, KinhinConfig.default.reserve.diskGB)
        XCTAssertEqual(snapshot.docker?.maxSlots, 4)
        XCTAssertEqual(snapshot.container?.minIdle, 0)
        XCTAssertEqual(snapshot.images.first?.minIdle, 1)
    }

    func testEachScalarFieldIsWrittenAndCommentsSurvive() throws {
        try seed()
        // 1 (xcode) + 1 + 1 + 1 = 4 fits max_runners 4.
        let edits: [GeneralConfigEditor.Field] = [
            .imageMinIdle(1), .containerMinIdle(1), .dockerMinIdle(1), .dockerMaxSlots(6), .reserveDiskGB(20),
            .warmMaxAgeMinutes(90),
        ]
        for field in edits { try GeneralConfigEditor.apply(field, to: file) }

        let snapshot = try GeneralConfigEditor.snapshot(from: text())
        XCTAssertEqual(snapshot.imageMinIdle, 1)
        XCTAssertEqual(snapshot.container?.minIdle, 1)
        XCTAssertEqual(snapshot.docker?.minIdle, 1)
        XCTAssertEqual(snapshot.docker?.maxSlots, 6)
        XCTAssertEqual(snapshot.reserveDiskGB, 20)
        XCTAssertEqual(snapshot.warmMaxAgeMinutes, 90)
        let written = try text()
        for comment in [
            "# kinhin configuration", "# fleet cap", "# warm VM lifetime", "# host cores kept back", "# the Linux pool",
            "# docker slots",
        ] {
            XCTAssertTrue(written.contains(comment), "\(comment) was dropped")
        }
        XCTAssertEqual(try ConfigLoader.parse(written).docker?.minIdle, 1)
    }

    func testAnEditedKeyKeepsItsTrailingComment() throws {
        try seed()
        try GeneralConfigEditor.apply(.dockerMaxSlots(3), to: file)
        let line = try XCTUnwrap(text().components(separatedBy: "\n").first { $0.contains("max_slots:") })
        XCTAssertTrue(line.hasPrefix("  max_slots: 3") && line.hasSuffix("# docker slots"), line)
    }

    func testImagesEditorRoundTripsMinIdle() throws {
        try seed()
        let images = try ImagesConfigEditor.parsed(from: text())
        XCTAssertEqual(images.first?.minIdle, 1)
        var edited = images
        edited[0].minIdle = 2
        try ImagesConfigEditor.apply(edited, to: file)
        XCTAssertEqual(try ImagesConfigEditor.parsed(from: text()).first?.minIdle, 2)
        XCTAssertTrue(try text().contains("# fleet cap"), "the rest of the file keeps its comments")
    }

    // MARK: - Rejected edits leave the file alone

    private func assertRejected(
        _ field: GeneralConfigEditor.Field, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try seed()
        let before = try text()
        XCTAssertThrowsError(try GeneralConfigEditor.apply(field, to: self.file), file: file, line: line) { error in
            guard case ConfigEditError.validation = error else {
                return XCTFail("expected a validation error, got \(error)", file: file, line: line)
            }
        }
        XCTAssertEqual(try text(), before, "a rejected edit must not touch the file", file: file, line: line)
    }

    func testAFloorAboveMaxRunnersIsRejected() throws {
        try assertRejected(.imageMinIdle(5))
        try assertRejected(.containerMinIdle(5))
        try assertRejected(.dockerMinIdle(5))
    }

    func testFloorsThatTogetherExceedMaxRunnersAreRejected() throws {
        try seed()
        try GeneralConfigEditor.apply(.containerMinIdle(2), to: file)
        try GeneralConfigEditor.apply(.dockerMinIdle(1), to: file)
        let before = try text()
        // 1 (xcode) + 2 + 1 + 1 = 5 > max_runners 4
        XCTAssertThrowsError(try GeneralConfigEditor.apply(.imageMinIdle(1), to: file))
        XCTAssertEqual(try text(), before)
    }

    func testDockerMinIdleAboveMaxSlotsIsRejected() throws {
        try seed()
        try GeneralConfigEditor.apply(.dockerMaxSlots(1), to: file)
        let before = try text()
        XCTAssertThrowsError(try GeneralConfigEditor.apply(.dockerMinIdle(2), to: file))
        XCTAssertEqual(try text(), before)
    }

    func testNegativeAndTooSmallValuesAreRejected() throws {
        try assertRejected(.imageMinIdle(-1))
        try assertRejected(.reserveDiskGB(-1))
        try assertRejected(.warmMaxAgeMinutes(1))
    }

    func testSectionFieldsNeedTheirSection() throws {
        try """
        accounts:
          - name: github
            forge: github
            scope: "acme"
        """.write(to: file, atomically: true, encoding: .utf8)
        let before = try text()
        XCTAssertThrowsError(try GeneralConfigEditor.apply(.dockerMinIdle(1), to: file)) { error in
            guard case ConfigEditError.unsupported = error else { return XCTFail("got \(error)") }
        }
        XCTAssertThrowsError(try GeneralConfigEditor.apply(.containerMinIdle(1), to: file))
        XCTAssertEqual(try text(), before)
    }
}
