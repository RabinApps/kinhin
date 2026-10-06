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
            "config init", "auth", "doctor", "setup-status", "setup repair host-agent", "runtimes route add",
            "runtimes route remove", "image prepare", "image list", "image delete", "image prune",
            "start", "stop", "pause", "resume", "status", "watch", "logs",
            "daemon", "support", "mcp", "version", "help",
        ] {
            XCTAssertTrue(help.contains(needle), "help should mention '\(needle)'")
        }
    }

    func testHelpTextAdvertisesEveryForgeInAuthAdd() {
        let help = helpText()
        for forge in ["--github", "--gitea", "--forgejo", "--gitlab", "--buildkite", "--azuredevops", "--bitbucket"] {
            XCTAssertTrue(help.contains(forge), "auth add help must list \(forge)")
        }
    }

    func testHelpTextSaysTheGitLabAndBuildkiteAgentInstallsAreConditional() {
        let help = helpText()
        XCTAssertTrue(
            help.contains(
                "gitlab-runner / buildkite-agent / the Azure Pipelines agent / the Bitbucket runner are added only when a GitLab / Buildkite / Azure DevOps / Bitbucket account is configured"
            ),
            "host-agent help must match HostAgentInstaller's conditional agent installs")
    }

    func testHelpTextMentionsProvisionScriptHook() {
        let help = helpText()
        XCTAssertTrue(help.contains("--provision-script"), "help should advertise the provision-script flag")
    }

    func testHelpTextMentionsToolchainFlagsAndCommand() {
        let help = helpText()
        XCTAssertTrue(help.contains("image prepare --project"), "help should advertise the per-project bake")
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

    func testHelpTextDescribesPerProjectBakesNotToolchainOverrides() {
        let help = helpText()
        XCTAssertTrue(help.contains("image prepare --project <owner/name>"), "help should advertise per-project bakes")
        for removed in ["--toolchain", "--stack", "--linux-toolchain", "--linux-stack"] {
            XCTAssertFalse(help.contains(removed), "\(removed) was removed and must not be advertised")
        }
        let project = try! XCTUnwrap(help.range(of: "image prepare --project"))
        let container = try! XCTUnwrap(help.range(of: "image prepare --container"))
        XCTAssertLessThan(project.lowerBound, container.lowerBound)
        XCTAssertTrue(help.contains("toolchains --project <owner/name>"))
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
