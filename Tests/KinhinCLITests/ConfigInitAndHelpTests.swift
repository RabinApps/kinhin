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

    // MARK: - config init

    func testConfigInitWritesTemplateWhenMissing() throws {
        try ConfigCommands.configInit([], configURL: configURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))

        // The written file must parse back as the template (no accounts yet).
        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        let cfg = try ConfigLoader.parse(yaml)
        XCTAssertTrue(cfg.accounts.isEmpty, "the template starts with no accounts")
    }

    /// A first run has no support directory yet (found by the end-to-end suite: `config init` failed with
    /// "The folder “config.yaml” doesn’t exist"), and the config must be private like every other support file.
    func testConfigInitCreatesTheMissingDirectoryAndKeepsTheFilePrivate() throws {
        let nested = scratch.appendingPathComponent("fresh/Kinhin/config.yaml")
        try ConfigCommands.configInit([], configURL: nested)

        let fileMode = try FileManager.default.attributesOfItem(atPath: nested.path)[.posixPermissions] as? Int
        let dirMode =
            try FileManager.default.attributesOfItem(atPath: nested.deletingLastPathComponent().path)[.posixPermissions]
            as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(dirMode, 0o700)
    }

    func testConfigInitNeverOverwritesExistingFile() throws {
        try "labels: [a]".write(to: configURL, atomically: true, encoding: .utf8)

        try ConfigCommands.configInit([], configURL: configURL)

        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(yaml, "labels: [a]", "an existing config must be left untouched")
    }

    func testConfigInitForceOverwritesExistingFile() throws {
        try "labels: [a]".write(to: configURL, atomically: true, encoding: .utf8)

        try ConfigCommands.configInit(["--force"], configURL: configURL)

        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        let cfg = try ConfigLoader.parse(yaml)
        XCTAssertTrue(cfg.accounts.isEmpty, "--force must replace the file with the template")
    }

    // MARK: - help text

    func testHelpTextMentionsEveryCommandFamily() {
        let help = helpText()
        for needle in [
            "config init", "auth set", "doctor", "setup status", "setup repair host-agent", "runtimes route add",
            "runtimes route remove", "image prepare", "image list", "image delete", "image prune",
            "image digest", "toolchains prune", "workflow test", "workflow route",
            "start", "stop", "pause", "resume", "status", "watch", "logs",
            "daemon", "support", "mcp", "version", "help",
        ] {
            XCTAssertTrue(help.contains(needle), "help should mention '\(needle)'")
        }
    }

    func testAuthAddPageAdvertisesEveryForge() {
        let page = helpText(for: ["auth", "add"])
        for forge in ["--github", "--gitea", "--forgejo", "--gitlab", "--buildkite", "--azuredevops", "--bitbucket"] {
            XCTAssertTrue(page.contains(forge), "auth add help must list \(forge)")
        }
    }

    func testHostAgentPageSaysTheOtherAgentInstallsAreConditional() {
        XCTAssertTrue(
            helpText(for: ["setup", "repair", "host-agent"]).contains("added only when such an account is configured"),
            "host-agent help must match HostAgentInstaller's conditional agent installs")
    }

    func testImagePreparePageMentionsProvisionScriptAndPerProjectBakes() {
        let page = helpText(for: ["image", "prepare"])
        XCTAssertTrue(page.contains("--provision-script"), "help should advertise the provision-script flag")
        XCTAssertTrue(page.contains("--project"), "help should advertise the per-project bake")
        XCTAssertTrue(helpText().contains("toolchains prune"), "help should advertise the manual cache prune")
        for removed in ["--toolchain", "--stack", "--linux-toolchain", "--linux-stack"] {
            XCTAssertFalse(page.contains(removed), "\(removed) was removed and must not be advertised")
        }
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

    func testHelpTextSpeaksKinhinAndMentionsEveryRuntime() {
        let help = helpText()
        XCTAssertTrue(help.contains("kinhin <command>"), "help usage lines must invoke kinhin")
        XCTAssertTrue(help.contains("Tart"), "help should name the macOS runtime")
        XCTAssertTrue(help.contains("apple/container"), "help should name the apple/container runtime")
        XCTAssertTrue(help.contains("Docker"), "help should name the Docker runtime")
        XCTAssertFalse(help.lowercased().contains("orchard"), "no pre-rename name may survive in help")
    }
}
