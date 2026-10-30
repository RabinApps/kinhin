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

    /// A curated Linux base cannot advertise `macos` — runner registration
    /// strips macOS-only labels — so carrying it in an image's labels would
    /// select jobs (ImageRouting requires every label) the runner can never
    /// serve. The loader rejects it up front, on the named entries and the
    /// default image (`image_labels:`); an entry without a Linux base keeps it.
    func testLinuxBaseImagesRejectMacosInTheirLabels() {
        let head = "accounts:\n  - name: github\n    forge: github\n    scope: \"a/b\"\nlabels: [self-hosted, macos]\n"
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                head + "images:\n  - name: linux\n    base_image: ghcr.io/cirruslabs/ubuntu:latest\n"
                    + "    labels: [macos, xcode]\n"),
            "a Linux runner never advertises macos")
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                head + "base_image: ghcr.io/cirruslabs/ubuntu:latest\nimage_labels: [macos, xcode]\n"),
            "a Linux default base never advertises macos either")
        XCTAssertNoThrow(
            try ConfigLoader.parse(head + "images:\n  - name: linux\n    labels: [linux, macos]\n"),
            "a macOS-based entry (no base_image) keeps macos")
    }

    // MARK: - Engine

    private func engine(
        images: [KinhinConfig.ImageConfig], fleetLabels: [String] = makeTestConfig().labels,
        baseImage: String? = nil, imageLabels: [String]? = nil
    ) -> (
        FleetEngine, FakeGitHub, FakeTart
    ) {
        var cfg = makeTestConfig()
        cfg.labels = fleetLabels
        cfg.images = images
        cfg.baseImage = baseImage
        cfg.imageLabels = imageLabels
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
        record.runtimeID = .tart
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

    /// The named image's own labels cannot reintroduce the macOS-only fleet
    /// labels either (config validation only rejects labels that are wholly
    /// fleet labels, so `labels: [macos, xcode]` parses): a Linux base strips
    /// them from the user labels too.
    func testLinuxNamedImageUserLabelsCannotReaddvertiseMacos() {
        let linuxImage = KinhinConfig.ImageConfig(
            name: "linux",
            baseImage: "ghcr.io/cirruslabs/ubuntu:latest",
            labels: ["macos", "xcode"])
        let (engine, _, _) = engine(images: [linuxImage], fleetLabels: ["self-hosted", "macos", "arm64"])
        var record = VMRecord(id: "kinhin-1")
        record.runtimeID = .tart
        record.image = "linux"
        let labels = engine.poolLabels(for: record) ?? []
        XCTAssertFalse(
            labels.contains { $0.lowercased() == "macos" },
            "the image's own macos label must not attract macOS jobs")
        XCTAssertTrue(labels.contains("xcode"), "the image's non-macos labels survive")
    }

    /// A custom/local image name whose OS cannot be reliably detected keeps the
    /// fleet labels as-is — we only strip `macos` for curated Linux bases.
    func testUnknownBaseImageKeepsFleetLabels() {
        let unknownImage = KinhinConfig.ImageConfig(
            name: "custom", baseImage: "my-local-vm", labels: ["custom"])
        let (engine, _, _) = engine(images: [unknownImage], fleetLabels: ["self-hosted", "macos", "arm64"])
        var record = VMRecord(id: "kinhin-1")
        record.runtimeID = .tart
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
        record.runtimeID = .tart
        record.image = "xcode"
        let labels = engine.poolLabels(for: record) ?? []
        XCTAssertTrue(
            labels.contains { $0.lowercased() == "macos" },
            "a macOS Tart VM still advertises macos")
        XCTAssertTrue(labels.contains("xcode"))
    }

    /// A Linux default `image:` (no `images:` entry claims it) must not attract
    /// macOS jobs either: its runners strip the fleet's `macos` label, which rides
    /// the snapshot's synthesized default-image entry (see `KinhinConfig.effectiveImages`).
    func testLinuxDefaultImageRunnersDoNotAdvertiseMacos() {
        let (engine, _, _) = engine(
            images: [], fleetLabels: ["self-hosted", "macos", "arm64"],
            baseImage: "ghcr.io/cirruslabs/ubuntu:latest")
        var record = VMRecord(id: "kinhin-1")
        record.runtimeID = .tart
        let labels = engine.poolLabels(for: record) ?? []
        XCTAssertFalse(
            labels.contains { $0.lowercased() == "macos" },
            "a Linux Tart default image must not advertise macos")
        XCTAssertTrue(
            labels.contains { $0.lowercased() == "self-hosted" },
            "non-macos fleet labels are retained")
    }

    /// `image_labels:` advertises the default image's own labels on its runners,
    /// named-entry style, without claiming them through an `images:` entry.
    func testImageLabelsAdvertiseOnDefaultImageRunners() {
        // macOS fleet labels are part of the set so the macOS default base is
        // proven to keep them; the fixture's own labels lack `macos`.
        let (engine, _, _) = engine(
            images: [], fleetLabels: ["self-hosted", "macos", "arm64"], imageLabels: ["linux-arm"])
        var record = VMRecord(id: "kinhin-1")
        record.runtimeID = .tart
        let labels = engine.poolLabels(for: record) ?? []
        XCTAssertTrue(labels.contains("linux-arm"), "the default image's labels are advertised")
        XCTAssertTrue(
            labels.contains { $0.lowercased() == "macos" },
            "a macOS default base keeps the fleet's macos label")
        // An explicit clone-source name equal to the default image resolves to the
        // same synthesized entry.
        record.image = makeTestConfig().image
        XCTAssertEqual(engine.poolLabels(for: record) ?? [], labels)
    }

    /// The labeled default image gets its own scale set, named after `image:`,
    /// so scale-set workflows can target it with `runs-on: <base>-<image>`.
    func testScaleSetPlanCoversTheLabeledDefaultImage() {
        let (engine, _, _) = engine(images: [], imageLabels: ["linux-arm"])
        let plan = engine.scaleSetPlan(
            account: AccountConfig(name: "github", forge: .github, scope: "a/b"), baseName: "kinhin")
        let entry = plan.first { $0.name == "kinhin-\(makeTestConfig().image)" }
        XCTAssertEqual(entry?.runtime, .tart)
        XCTAssertTrue(entry?.labels.contains("linux-arm") ?? false)
    }

    // MARK: - Default-image label validation

    func testImageLabelsTopLevelValidation() {
        let head =
            "accounts:\n  - name: github\n    forge: github\n    scope: \"a/b\"\n"
            + "labels: [self-hosted, macos, arm64]\n"
        XCTAssertThrowsError(
            try ConfigLoader.parse(head + "image_labels: [self-hosted, macos, arm64]\n"),
            "every job would match the default image")
        XCTAssertThrowsError(
            try ConfigLoader.parse(head + "image_labels: [linux]\nimages:\n  - name: x\n    labels: [LINUX]\n"),
            "jobs could not tell a named image and the default image apart")
        XCTAssertThrowsError(
            try ConfigLoader.parse(head + "image_labels: [linux, \"\"]\n"), "empty label")
        XCTAssertNoThrow(try ConfigLoader.parse(head + "image_labels: [linux]\n"))
        XCTAssertNoThrow(
            try ConfigLoader.parse(head + "image_labels: [linux]\nimages:\n  - name: x\n    labels: [xcode]\n"))
    }

    func testFleetLabelsToggleParses() throws {
        let head =
            "accounts:\n  - name: github\n    forge: github\n    scope: \"a/b\"\n"
            + "labels: [self-hosted, macos, arm64]\n"
        let container = try ConfigLoader.parse(head + "container:\n  image: kinhin-ci-linux\n  fleet_labels: false\n")
        XCTAssertEqual(container.container?.fleetLabels, false)
        let docker = try ConfigLoader.parse(
            head + "docker:\n  image: kinhin-ci-linux\n  fleet_labels: false\n")
        XCTAssertEqual(docker.docker?.fleetLabels, false)
        let defaults = try ConfigLoader.parse(head + "container:\n  image: kinhin-ci-linux\n")
        XCTAssertNil(defaults.container?.fleetLabels)
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
        record.runtimeID = .tart
        let base = engine.poolLabels(for: record)
        record.image = "xcode"
        let labels = engine.poolLabels(for: record)
        XCTAssertEqual(labels, (base ?? []) + ["xcode"])
        record.image = "some-derived-image"
        XCTAssertEqual(engine.poolLabels(for: record), base, "derived project images add no labels")
    }
}
