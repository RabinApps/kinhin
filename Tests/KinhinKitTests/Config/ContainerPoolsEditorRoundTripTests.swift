import XCTest

@testable import KinhinKit

/// Every editor the app saves settings through, run on a config with `container.pools:`: none may drop a pool, a
/// key a pool sets, or one it leaves to the section's defaults. The editors that rewrite the whole `container:`
/// section (the Apple container toggle, its base image, its labels, the pools editor) are the ones at risk; the
/// others are here so a future rewrite of theirs is caught too.
final class ContainerPoolsEditorRoundTripTests: XCTestCase {
    /// Every pool key, in both YAML styles, a pool that sets nothing, and a section without an image of its own.
    private static let yaml = """
        accounts:
          - name: github
            forge: github
            scope: "acme"
        labels: [self-hosted, arm64]
        max_runners: 10
        # the Linux pools
        container:
          base_image: "ubuntu:24.04"
          cpus: 2
          memory_gb: 7
          labels: [linux]
          docker: true
          pools:
            linux: { image: kinhin-ci-linux, min_idle: 1 }
            big:
              image: kinhin-ci-linux
              labels: [linux, big]
              cpus: 4
              memory_gb: 12
              flags: ["--shm-size", "2g"]
              max: 2
            gpu:
              image: "kinhin-ci-gpu"
              base_image: "debian:12"
              labels: [gpu]
              fleet_labels: false
              docker: false
              min_idle: 0
            plain: { image: kinhin-ci-linux, labels: [plain] }

        """

    private var url: URL!
    private var writtenPools: [GeneralConfigEditor.Snapshot.ContainerPool] = []
    private var effectivePools: [KinhinConfig.ContainerConfig.Pool] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pools-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        url = dir.appendingPathComponent("config.yaml")
        try Self.yaml.write(to: url, atomically: true, encoding: .utf8)
        writtenPools = try XCTUnwrap(GeneralConfigEditor.snapshot(from: Self.yaml).container?.pools)
        effectivePools = try XCTUnwrap(ConfigLoader.parse(Self.yaml).container?.pools)
        XCTAssertEqual(writtenPools.map(\.name), ["big", "gpu", "linux", "plain"])
    }

    /// The pools as written are unchanged, and, unless the edit changed a section default, so is what they resolve to.
    private func assertPoolsKept(
        after edit: String, sectionDefaultsChanged: Bool = false, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(
            try GeneralConfigEditor.snapshot(from: text).container?.pools, writtenPools,
            "\(edit) changed the pools as written:\n\(text)", file: file, line: line)
        if !sectionDefaultsChanged {
            XCTAssertEqual(
                try ConfigLoader.parse(text).container?.pools, effectivePools,
                "\(edit) changed what the pools resolve to:\n\(text)", file: file, line: line)
        }
    }

    // MARK: - Editors that rewrite container:

    func testTheAppleContainerToggleKeepsThePools() throws {
        // This Mac's checkbox writes the snapshot's section back when it is (re)ticked.
        let container = try XCTUnwrap(ConfigStore.snapshot(at: url)?.container)
        try GeneralConfigEditor.apply(.container(container), to: url)
        try assertPoolsKept(after: "the container toggle")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("  image:\n"), "no empty section image")
        XCTAssertEqual(
            try GeneralConfigEditor.snapshot(from: text).container?.image, "",
            "the section still names no image of its own:\n\(text)")
        XCTAssertTrue(text.contains("# the Linux pools\ncontainer:"), "the comment above the section stays")
    }

    func testTheContainerBaseImageKeepsThePools() throws {
        try GeneralConfigEditor.setBaseImage("debian:13", for: .appleContainer, at: url)
        try assertPoolsKept(after: "the base image picker", sectionDefaultsChanged: true)
        let container = try XCTUnwrap(ConfigLoader.load(from: url).container)
        XCTAssertEqual(container.pool(named: "gpu").baseImage, "debian:12", "a pool's own base image stays")
        try GeneralConfigEditor.setBaseImage(nil, for: .appleContainer, at: url)
        try assertPoolsKept(after: "clearing the base image", sectionDefaultsChanged: true)
    }

    func testTheContainerLabelsKeepThePools() throws {
        try LabelsConfigEditor.apply(["linux", "arm"], scope: .container, to: url)
        try assertPoolsKept(after: "the container labels field", sectionDefaultsChanged: true)
        XCTAssertEqual(
            try LabelsConfigEditor.labels(in: String(contentsOf: url, encoding: .utf8), scope: .container),
            ["linux", "arm"])
    }

    func testThePoolsEditorKeepsTheOtherPools() throws {
        try ContainerPoolsConfigEditor.save(
            .init(name: "extra", image: "kinhin-ci-linux", labels: ["extra"]), replacing: nil, at: url)
        try ContainerPoolsConfigEditor.remove(named: "extra", at: url)
        try assertPoolsKept(after: "adding and removing another pool")
    }

    // MARK: - Editors that leave container: alone

    func testTheGeneralFieldsKeepThePools() throws {
        let fields: [GeneralConfigEditor.Field] = [
            .labels(["self-hosted", "arm64", "extra"]), .minRunners(1), .maxRunners(12), .warmPool(0),
            .pollInterval(30), .autoResume(true), .vmCPU(4), .vmMemoryGB(8), .vmEphemeral(true), .image("macos-27"),
            .baseImage("ghcr.io/cirruslabs/macos-tahoe-xcode:latest"), .baseImage(nil), .reserveCPU(2),
            .reserveMemoryGB(4),
            .docker(.init(image: "kinhin-ci-linux", cpus: 2, memoryGB: 4, maxSlots: 4)), .docker(nil),
        ]
        for field in fields {
            try GeneralConfigEditor.apply(field, to: url)
            try assertPoolsKept(after: "\(field)")
        }
    }

    func testTheRoutingImagesAccountsAndTelemetryEditorsKeepThePools() throws {
        try RuntimesConfigEditor.apply(
            .init(
                defaultRuntime: .appleContainer, budget: ["tart": 0.3],
                routes: [.init(pattern: "acme/api", runtime: .appleContainer)]), to: url)
        try assertPoolsKept(after: "the routing editor")
        try ImagesConfigEditor.apply([.init(name: "macos-xcode", labels: ["xcode"])], to: url)
        try assertPoolsKept(after: "the images editor")
        try AccountsConfigEditor.add(AccountConfig(name: "work", forge: .github, scope: "bigco"), to: url)
        try assertPoolsKept(after: "the accounts editor")
        try TelemetryConfigEditor.apply(.enabled(false), to: url)
        try assertPoolsKept(after: "the telemetry editor")
    }

    func testTheWholeFileEditorKeepsThePools() throws {
        try ConfigEditor.save(String(contentsOf: url, encoding: .utf8), to: url)
        try assertPoolsKept(after: "Edit YAML")
    }
}
