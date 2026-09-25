import XCTest

@testable import KinhinKit
@testable import kinhin

final class ConfigInitAndHelpTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var configURL: URL { scratch.appendingPathComponent("config.yaml") }

    // MARK: config init

    func testConfigInitWritesTemplateWhenMissing() throws {
        try ConfigCommands.configInit([], configURL: configURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))

        // The written file must parse back as a valid (template) config.
        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        let cfg = try ConfigLoader.parse(yaml)
        XCTAssertEqual(cfg.repo, ConfigLoader.templateRepo)
    }

    func testConfigInitNeverOverwritesExistingFile() throws {
        try "repo: acme/custom".write(to: configURL, atomically: true, encoding: .utf8)

        try ConfigCommands.configInit([], configURL: configURL)

        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(yaml, "repo: acme/custom", "an existing config must be left untouched")
    }

    func testConfigInitForceOverwritesExistingFile() throws {
        try "repo: acme/custom".write(to: configURL, atomically: true, encoding: .utf8)

        try ConfigCommands.configInit(["--force"], configURL: configURL)

        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        let cfg = try ConfigLoader.parse(yaml)
        XCTAssertEqual(cfg.repo, ConfigLoader.templateRepo, "--force must replace the file with the template")
    }

    // MARK: help text

    func testHelpTextMentionsEveryCommandFamily() {
        let help = helpText()
        for needle in [
            "config init", "auth", "doctor", "setup-status", "runtimes route add",
            "runtimes route remove", "image prepare",
            "start", "stop", "pause", "resume", "status", "watch", "logs",
            "daemon", "version", "help",
        ] {
            XCTAssertTrue(help.contains(needle), "help should mention '\(needle)'")
        }
    }

    func testHelpTextMentionsProvisionScriptHook() {
        let help = helpText()
        XCTAssertTrue(help.contains("--provision-script"), "help should advertise the provision-script flag")
    }

    func testHelpTextMentionsToolchainFlagsAndCommand() {
        let help = helpText()
        XCTAssertTrue(help.contains("--toolchain"), "help should advertise the managed-toolchain override flag")
        XCTAssertTrue(help.contains("toolchains prune"), "help should advertise the manual cache prune")
    }

    func testHelpTextStaysHonestAboutSetupOrder() {
        let help = helpText()
        // The guided order matters: config → auth → image → start.
        let config = try! XCTUnwrap(help.range(of: "config init"))
        let auth = try! XCTUnwrap(help.range(of: "auth set"))
        let image = try! XCTUnwrap(help.range(of: "image prepare"))
        let start = try! XCTUnwrap(help.range(of: "start "))
        XCTAssertLessThan(config.lowerBound, auth.lowerBound)
        XCTAssertLessThan(auth.lowerBound, image.lowerBound)
        XCTAssertLessThan(image.lowerBound, start.lowerBound)
    }

    func testHelpTextMentionsLinuxToolchainOverridesForBothContainerRuntimes() {
        let help = helpText()
        XCTAssertTrue(help.contains("--linux-toolchain"), "help should advertise the Linux bake override")
        let docker = try! XCTUnwrap(help.range(of: "--docker"))
        let bakes = try! XCTUnwrap(help.range(of: "bakes `toolchains:` the same way"))
        XCTAssertLessThan(docker.lowerBound, bakes.lowerBound, "the docker line documents the same toolchain bake")
    }

    func testHelpTextSpeaksKinhinAndMentionsEveryRuntime() {
        let help = helpText()
        XCTAssertTrue(help.contains("kinhin <command>"), "help usage lines must invoke kinhin")
        XCTAssertTrue(help.contains("Tart"), "help should name the macOS runtime")
        XCTAssertTrue(help.contains("apple/container"), "help should name the apple/container runtime")
        XCTAssertTrue(help.contains("Docker"), "help should name the Docker runtime")
        XCTAssertFalse(help.lowercased().contains("orchard"), "no pre-rename name may survive in help")
    }
}
