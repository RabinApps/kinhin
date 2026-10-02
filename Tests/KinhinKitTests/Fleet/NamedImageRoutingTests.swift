import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Jobs that request a named image's labels run on that image; others run on `image:`.
final class NamedImageRoutingTests: XCTestCase {
    private let xcode = KinhinConfig.ImageConfig(
        name: "xcode", baseImage: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest", labels: ["xcode"])

    // MARK: - Matching

    func testMatchesWhenAllImageLabelsAreRequested() {
        XCTAssertEqual(ImageRouting.image(for: ["self-hosted", "macOS", "XCODE"], in: [xcode])?.name, "xcode")
        XCTAssertNil(ImageRouting.image(for: ["self-hosted", "macos"], in: [xcode]))
        XCTAssertNil(ImageRouting.image(for: nil, in: [xcode]))
        XCTAssertNil(ImageRouting.image(for: ["xcode"], in: [.init(name: "unlabeled")]), "no labels = not selectable")
    }

    func testMostSpecificImageWins() {
        let plain = KinhinConfig.ImageConfig(name: "a", labels: ["xcode"])
        let pinned = KinhinConfig.ImageConfig(name: "b", labels: ["xcode", "xcode-26"])
        XCTAssertEqual(ImageRouting.image(for: ["xcode", "xcode-26"], in: [plain, pinned])?.name, "b")
        XCTAssertEqual(ImageRouting.image(for: ["xcode"], in: [plain, pinned])?.name, "a")
    }

    // MARK: - Config validation

    func testImageLabelsMustAddSomethingBeyondTheFleetLabels() {
        let head = "accounts:\n  - name: github\n    forge: github\n    scope: \"a/b\"\nlabels: [self-hosted, macos]\n"
        XCTAssertThrowsError(
            try ConfigLoader.parse(head + "images:\n  - name: x\n    labels: [macos]\n"), "every job would match")
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                head + "images:\n  - name: x\n    labels: [xcode]\n  - name: y\n    labels: [XCODE]\n"))
        XCTAssertNoThrow(try ConfigLoader.parse(head + "images:\n  - name: x\n    labels: [macos, xcode]\n"))
    }

    // MARK: - Engine

    private func engine(images: [KinhinConfig.ImageConfig]) -> (FleetEngine, FakeGitHub, FakeTart) {
        var cfg = makeTestConfig()
        cfg.images = images
        let github = FakeGitHub()
        let tart = FakeTart()
        let engine = FleetEngine(
            config: cfg, github: github, tart: tart, store: makeTestStore(), ssh: FakeSSH(), host: testHost)
        return (engine, github, tart)
    }

    func testLabeledJobsCloneTheNamedImage() async throws {
        let (engine, github, tart) = engine(images: [xcode])
        github.queueDepth = 1
        github.queueExtraLabels = ["xcode"]
        try await engine.reconcileOnce()
        XCTAssertEqual(tart.cloneCalls.first?.source, "xcode")
        let records = await engine.status().records
        XCTAssertEqual(records.first?.image, "xcode")
    }

    func testUnlabeledJobsStayOnTheMainImage() async throws {
        let (engine, github, tart) = engine(images: [xcode])
        github.queueDepth = 1
        try await engine.reconcileOnce()
        XCTAssertEqual(tart.cloneCalls.first?.source, "tahoe-base")
        let records = await engine.status().records
        XCTAssertNil(records.first?.image)
    }

    func testNamedImageRunnersAdvertiseTheImageLabels() {
        let (engine, _, _) = engine(images: [xcode])
        var record = VMRecord(id: "kinhin-1")
        record.runtime = RuntimeID.tart.rawValue
        let base = engine.poolLabels(for: record)
        record.image = "xcode"
        let labels = engine.poolLabels(for: record)
        XCTAssertEqual(labels, (base ?? []) + ["xcode"])
        record.image = "some-derived-image"
        XCTAssertEqual(engine.poolLabels(for: record), base, "derived project images add no labels")
    }
}
