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

    private func engine(images: [KinhinConfig.ImageConfig], fleetLabels: [String] = makeTestConfig().labels) -> (
        FleetEngine, FakeGitHub, FakeTart
    ) {
        var cfg = makeTestConfig()
        cfg.labels = fleetLabels
        cfg.images = images
        let github = FakeGitHub()
        let tart = FakeTart()
        let engine = FleetEngine(
            config: cfg, github: github, tart: tart, store: makeTestStore(), ssh: FakeSSH(), host: testHost)
        return (engine, github, tart)
    }

    // MARK: - Linux named image label hygiene

    /// A Tart VM cloned from a Linux named image must not advertise
    /// macOS-only fleet labels (`macos`), so it does not attract macOS jobs.
    func testLinuxNamedImageRunnersDoNotAdvertiseMacos() {
        let linuxImage = KinhinConfig.ImageConfig(
            name: "linux",
            baseImage: "ghcr.io/cirruslabs/ubuntu:latest",
            labels: ["linux"])
        let (engine, _, _) = engine(images: [linuxImage], fleetLabels: ["self-hosted", "macos", "arm64"])
        var record = VMRecord(id: "kinhin-1")
        record.runtime = RuntimeID.tart.rawValue
        let base = engine.poolLabels(for: record) ?? []
        // The base pool carries the fleet labels (including macos).
        XCTAssertTrue(base.contains { $0.lowercased() == "macos" }, "fleet labels include macos")
        record.image = "linux"
        let linuxLabels = engine.poolLabels(for: record) ?? []
        XCTAssertFalse(
            linuxLabels.contains { $0.lowercased() == "macos" },
            "a Linux Tart VM must not advertise macos")
        XCTAssertTrue(linuxLabels.contains("linux"), "the image's own labels are still advertised")
        XCTAssertTrue(
            linuxLabels.contains { $0.lowercased() == "self-hosted" },
            "non-macos fleet labels are retained")
    }

    /// A custom/local image name whose OS cannot be reliably detected keeps the
    /// fleet labels as-is — we only strip `macos` for curated Linux bases.
    func testUnknownBaseImageKeepsFleetLabels() {
        let unknownImage = KinhinConfig.ImageConfig(
            name: "custom", baseImage: "my-local-vm", labels: ["custom"])
        let (engine, _, _) = engine(images: [unknownImage], fleetLabels: ["self-hosted", "macos", "arm64"])
        var record = VMRecord(id: "kinhin-1")
        record.runtime = RuntimeID.tart.rawValue
        record.image = "custom"
        let labels = engine.poolLabels(for: record) ?? []
        XCTAssertTrue(
            labels.contains { $0.lowercased() == "macos" },
            "an unidentifiable base keeps fleet labels as-is")
        XCTAssertTrue(labels.contains("custom"))
    }

    /// A macOS named image still advertises the fleet's macos label.
    func testMacOSNamedImageStillAdvertisesMacos() {
        let macosImage = KinhinConfig.ImageConfig(
            name: "xcode",
            baseImage: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest",
            labels: ["xcode"])
        let (engine, _, _) = engine(images: [macosImage], fleetLabels: ["self-hosted", "macos", "arm64"])
        var record = VMRecord(id: "kinhin-1")
        record.runtime = RuntimeID.tart.rawValue
        record.image = "xcode"
        let labels = engine.poolLabels(for: record) ?? []
        XCTAssertTrue(
            labels.contains { $0.lowercased() == "macos" },
            "a macOS Tart VM still advertises macos")
        XCTAssertTrue(labels.contains("xcode"))
    }

    func testLabeledJobsCloneTheNamedImage() async throws {
        let (engine, github, tart) = engine(images: [xcode])
        github.queueDepth = 1
        github.queueExtraLabels = ["xcode"]
        try await engine.reconcileOnce()
        await waitForCondition { !tart.cloneCalls.isEmpty }
        XCTAssertEqual(tart.cloneCalls.first?.source, "xcode")
        let records = await engine.status().records
        XCTAssertEqual(records.first?.image, "xcode")
    }

    func testUnlabeledJobsStayOnTheMainImage() async throws {
        let (engine, github, tart) = engine(images: [xcode])
        github.queueDepth = 1
        try await engine.reconcileOnce()
        await waitForCondition { !tart.cloneCalls.isEmpty }
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
