import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class BaseImageConfigTests: XCTestCase {
    private let head =
        "accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\nlabels: [self-hosted]\n"

    // MARK: parsing

    func testAbsentBaseImageIsNilAndResolvesToTheDefault() throws {
        let cfg = try ConfigLoader.parse(head + "container:\n  image: \"kinhin-ci-linux\"\n")
        XCTAssertNil(cfg.container?.baseImage)
        XCTAssertEqual(LinuxBaseImage.resolve(configured: cfg.container?.baseImage), "ubuntu:24.04")
    }

    func testBaseImageParsesForContainerAndDocker() throws {
        let cfg = try ConfigLoader.parse(
            head
                + "container:\n  image: \"a\"\n  base_image: \"debian:12\"\n"
                + "docker:\n  image: \"b\"\n  base_image: \"ubuntu:22.04\"\n")
        XCTAssertEqual(cfg.container?.baseImage, "debian:12")
        XCTAssertEqual(cfg.docker?.baseImage, "ubuntu:22.04")
    }

    func testUnusableBaseImagesAreRejectedWithTheKeyName() {
        for (section, value) in [
            ("container", ""), ("container", "--privileged"), ("docker", "ubuntu 24.04"), ("docker", "-v x"),
        ] {
            XCTAssertThrowsError(
                try ConfigLoader.parse(head + "\(section):\n  image: \"x\"\n  base_image: \"\(value)\"\n"), value
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("\(section).base_image"), "\(error)")
            }
        }
    }

    // MARK: resolution

    func testFlagBeatsConfigBeatsDefault() {
        XCTAssertEqual(LinuxBaseImage.resolve(configured: "debian:12", flagOverride: "ubuntu:22.04"), "ubuntu:22.04")
        XCTAssertEqual(LinuxBaseImage.resolve(configured: "debian:12", flagOverride: nil), "debian:12")
        XCTAssertEqual(LinuxBaseImage.resolve(configured: nil, flagOverride: "  "), "ubuntu:24.04")
    }

    func testRebuildStartsFromTheConfiguredBaseWhenNothingWasBakedYet() {
        XCTAssertEqual(
            LinuxImageOptions.baseImage(configured: "out", localImages: [], fallback: "debian:12"), "debian:12")
        XCTAssertEqual(
            LinuxImageOptions.baseImage(configured: "out", localImages: ["out:latest"], fallback: "debian:12"), "out")
    }

    // MARK: editor

    private func editing(_ yaml: String) throws -> (URL, () throws -> String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        return (file, { try String(contentsOf: file, encoding: .utf8) })
    }

    func testEditorWritesBaseImageOnlyWhenSetAndKeepsContainerLabels() throws {
        let (file, read) = try editing(
            head + "container:\n  image: \"kinhin-ci-linux\"\n  cpus: 4\n  memory_gb: 8\n  labels: [\"gpu\"]\n")
        var snap = try XCTUnwrap(GeneralConfigEditor.snapshot(from: read()).container)
        XCTAssertNil(snap.baseImage)
        XCTAssertEqual(snap.labels, ["gpu"])

        snap.baseImage = "debian:12"
        _ = try GeneralConfigEditor.apply(.container(snap), to: file)
        XCTAssertTrue(try read().contains("base_image: \"debian:12\""))
        XCTAssertTrue(try read().contains("labels: [\"gpu\"]"), "a section rewrite must not drop labels")
        XCTAssertEqual(try ConfigLoader.parse(read()).container?.baseImage, "debian:12")

        snap.baseImage = nil
        _ = try GeneralConfigEditor.apply(.container(snap), to: file)
        XCTAssertFalse(try read().contains("base_image"), "the default is written as no key at all")
    }

    func testEditorRoundTripsDockerBaseImage() throws {
        let (file, read) = try editing(head + "docker:\n  image: \"kinhin-ci-linux\"\n")
        var docker = try XCTUnwrap(GeneralConfigEditor.snapshot(from: read()).docker)
        docker.baseImage = "ubuntu:22.04"
        _ = try GeneralConfigEditor.apply(.docker(docker), to: file)
        XCTAssertEqual(try ConfigLoader.parse(read()).docker?.baseImage, "ubuntu:22.04")
    }

    func testEditorRejectsAnUnusableBaseImageBeforeWriting() throws {
        let (file, read) = try editing(head + "docker:\n  image: \"kinhin-ci-linux\"\n")
        let before = try read()
        var docker = try XCTUnwrap(GeneralConfigEditor.snapshot(from: before).docker)
        docker.baseImage = "--privileged"
        XCTAssertThrowsError(try GeneralConfigEditor.apply(.docker(docker), to: file))
        XCTAssertEqual(try read(), before, "nothing is written when validation fails")
    }

    // MARK: preflight

    func testNonAptBaseFailsBeforeAnyAgentDownload() async {
        let shell = FakeShell()
        shell.failOn = "command -v apt-get"
        let options = LinuxImageOptions(
            image: "alpine:3.20", target: "out", hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false)
        do {
            _ = try await ContainerImagePreparer(shell: shell).prepare(
                options, versions: .init(github: "1", gitea: "1"))
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("isn't Debian/Ubuntu-based"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("alpine:3.20"))
        }
        XCTAssertFalse(shell.calls.contains { $0.contains { $0.contains("actions-runner") } }, "no agent install ran")
        XCTAssertFalse(
            shell.calls.contains { $0.contains("export") || $0.contains("build") }, "never got to the commit")
    }
}

final class SetBaseImageTests: XCTestCase {
    private func file(_ yaml: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sbi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let both =
        "accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\nlabels: [self-hosted]\n# keep me\ncontainer:\n  image: \"c\"\ndocker:\n  image: \"d\"\n"

    func testSetsEachRuntimeIndependentlyAndKeepsComments() throws {
        let url = try file(both)
        try GeneralConfigEditor.setBaseImage("debian:12", for: .appleContainer, at: url)
        try GeneralConfigEditor.setBaseImage("ubuntu:22.04", for: .docker, at: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("# keep me"))
        let cfg = try ConfigLoader.load(from: url)
        XCTAssertEqual(cfg.container?.baseImage, "debian:12")
        XCTAssertEqual(cfg.docker?.baseImage, "ubuntu:22.04")
        let snapshot = try XCTUnwrap(ConfigStore.snapshot(at: url))
        XCTAssertEqual(snapshot.baseImage(for: .docker), "ubuntu:22.04")

        try GeneralConfigEditor.setBaseImage(nil, for: .docker, at: url)
        XCTAssertNil(try ConfigLoader.load(from: url).docker?.baseImage)
        XCTAssertEqual(try ConfigLoader.load(from: url).container?.baseImage, "debian:12")
    }

    func testRefusesWhenTheRuntimeIsNotConfiguredOrNotLinux() throws {
        let url = try file(
            "accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\nlabels: [self-hosted]\ndocker:\n  image: \"d\"\n"
        )
        XCTAssertThrowsError(try GeneralConfigEditor.setBaseImage("debian:12", for: .appleContainer, at: url))
    }

    func testTartBaseImageRoundTripsAndClearsToTheDefault() throws {
        let url = try file(both)
        try GeneralConfigEditor.setBaseImage("ghcr.io/cirruslabs/macos-sequoia-base:latest", for: .tart, at: url)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.contains("base_image: \"ghcr.io/cirruslabs/macos-sequoia-base:latest\""), written)
        XCTAssertTrue(written.contains("# keep me"), "the edit must not disturb the rest of the file")
        let cfg = try ConfigLoader.load(from: url)
        XCTAssertEqual(cfg.baseImage, "ghcr.io/cirruslabs/macos-sequoia-base:latest")
        let snapshot = try XCTUnwrap(ConfigStore.snapshot(at: url))
        XCTAssertEqual(snapshot.baseImage(for: .tart), cfg.baseImage)

        // Clearing removes the key: the default must never be pinned in.
        try GeneralConfigEditor.setBaseImage(nil, for: .tart, at: url)
        let cleared = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(cleared.contains("base_image:"), cleared)
        XCTAssertNil(try ConfigLoader.load(from: url).baseImage)
    }

    func testTartBaseImageRejectsHazardousReferencesBeforeWriting() throws {
        let url = try file(both)
        XCTAssertThrowsError(
            try GeneralConfigEditor.setBaseImage("--privileged", for: .tart, at: url))
        XCTAssertThrowsError(try GeneralConfigEditor.setBaseImage("two words", for: .tart, at: url))
        XCTAssertNil(try ConfigLoader.load(from: url).baseImage, "a rejected edit must not write")
    }
}

final class LinuxBaseImageCatalogTests: XCTestCase {
    func testCuratedListIsValidUniqueAndIncludesTheDefault() {
        let references = LinuxBaseImage.curated.map(\.reference)
        XCTAssertEqual(Set(references).count, references.count, "no duplicates")
        XCTAssertEqual(Set(LinuxBaseImage.curated.map(\.title)).count, references.count, "titles are distinct")
        XCTAssertTrue(references.contains(LinuxBaseImage.defaultReference))
        for reference in references {
            XCTAssertNil(LinuxBaseImage.problem(with: reference), reference)
            XCTAssertTrue(
                reference.hasPrefix("ubuntu:") || reference.hasPrefix("debian:"),
                "\(reference): install scripts use apt-get, so bases must be Debian or Ubuntu")
        }
    }
}
