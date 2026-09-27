import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ToolchainHelperScriptTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin helper \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Temp dir; a leftover is harmless.
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - Generated content

    func testEveryPlatformEntryGetsACaseArm() {
        for platform in ToolchainPlatform.allCases {
            let script = RunnerBootstrap.toolchainHelperScript(platform: platform, mountPath: "/mnt/cache")
            for tool in ToolchainCatalog.tools {
                XCTAssertEqual(
                    script.contains("'\(tool.id):0')"), tool.platforms.contains(platform), "\(tool.id) on \(platform)")
            }
            for stack in ToolchainCatalog.stacks {
                XCTAssertEqual(
                    script.contains("'\(stack.id):0')"), stack.platforms.contains(platform),
                    "\(stack.id) on \(platform)")
            }
        }
    }

    func testLinuxHelperLeavesOutMacOSOnlyRecipes() {
        let script = RunnerBootstrap.toolchainHelperScript(platform: .linux, mountPath: "/var/kinhin-cache")
        XCTAssertFalse(script.contains("'react-native:0')"))
        XCTAssertFalse(script.contains("brew install"), "Linux guests have no Homebrew")
    }

    func testOnlyVersionAwareInstallersGetAVersionedBody() throws {
        let entries = ToolchainHelperEntry.entries(platform: .macOS, mountPath: "/mnt/cache")
        let node = try XCTUnwrap(entries.first { $0.id == "node" })
        XCTAssertTrue(try XCTUnwrap(node.versionedBody).contains("node@\(ToolchainHelperEntry.versionSentinel)"))
        XCTAssertFalse(node.defaultBody.contains(ToolchainHelperEntry.versionSentinel))
        let yamllint = try XCTUnwrap(entries.first { $0.id == "yamllint" })
        XCTAssertNil(yamllint.versionedBody, "brew formulas ignore versions")
        let flutter = try XCTUnwrap(entries.first { $0.id == "flutter" })
        XCTAssertTrue(
            try XCTUnwrap(flutter.versionedBody).contains("fvm install \(ToolchainHelperEntry.versionSentinel)"))
    }

    func testCatalogIDsAreUniqueAcrossToolsAndStacks() {
        let ids = ToolchainCatalog.tools.map(\.id) + ToolchainCatalog.stacks.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "a shared id would shadow a helper case arm")
    }

    func testNoBodyContainsTheHeredocDelimiter() {
        for platform in ToolchainPlatform.allCases {
            for entry in ToolchainHelperEntry.entries(platform: platform, mountPath: "/mnt/cache") {
                for body in [entry.defaultBody, entry.versionedBody ?? ""] {
                    XCTAssertFalse(
                        body.split(separator: "\n").contains { $0 == RunnerBootstrap.toolchainHelperBodyDelimiter },
                        entry.id)
                }
            }
        }
    }

    func testGeneratedScriptsParseUnderBash() async throws {
        for platform in ToolchainPlatform.allCases {
            let path = workDir.appendingPathComponent("helper-\(platform.rawValue).sh")
            try ToolchainCatalog.helperScript(for: platform).write(to: path, atomically: true, encoding: .utf8)
            let result = try await Shell().run(["/bin/bash", "-n", path.path])
            XCTAssertTrue(result.succeeded, "\(platform): \(result.stderr)")
        }
    }

    // MARK: - Runtime behavior (stub installers on PATH)

    func testInstallRunsTheCatalogBodyWithThePinnedVersion() async throws {
        let run = try await runHelper(["install", "go@1.23"])
        XCTAssertTrue(run.result.succeeded, run.result.stderr)
        XCTAssertTrue(run.calls.contains("mise use --global go@1.23"), run.calls)
        XCTAssertTrue(run.calls.contains("go version"), "the verify command runs: \(run.calls)")
    }

    func testRuntimeProvidersInstallFirstAndPersistForLaterSteps() async throws {
        let run = try await runHelper(["install", "pnpm", "node@22"])
        XCTAssertTrue(run.result.succeeded, run.result.stderr)
        let node = try XCTUnwrap(run.calls.range(of: "mise use --global node@22"))
        let pnpm = try XCTUnwrap(run.calls.range(of: "npm install -g pnpm"))
        XCTAssertLessThan(node.lowerBound, pnpm.lowerBound, "node installs before the npm global that needs it")
        XCTAssertTrue(run.githubPath.contains(".local/share/mise/shims"), run.githubPath)
        XCTAssertTrue(run.githubEnv.contains("NPM_CONFIG_CACHE=\(run.mount)/npm"), run.githubEnv)
    }

    func testUnknownIDsPassThroughToMise() async throws {
        let run = try await runHelper(["install", "ubi:owner/tool@1.0"])
        XCTAssertTrue(run.result.succeeded, run.result.stderr)
        XCTAssertTrue(run.calls.contains("mise use --global ubi:owner/tool@1.0"), run.calls)
    }

    func testRejectsShellMetacharactersBeforeInstallingAnything() async throws {
        let run = try await runHelper(["install", "go@1;touch pwned"])
        XCTAssertFalse(run.result.succeeded)
        XCTAssertTrue(run.result.stderr.contains("invalid spec"), run.result.stderr)
        XCTAssertTrue(run.calls.isEmpty, run.calls)
    }

    func testRejectsAVersionOnInstallersThatIgnoreIt() async throws {
        let run = try await runHelper(["install", "yamllint@1.0"])
        XCTAssertFalse(run.result.succeeded)
        XCTAssertTrue(run.result.stderr.contains("does not take a version"), run.result.stderr)
    }

    func testMissingRequirementFailsWithTheFix() async throws {
        let run = try await runHelper(["install", "pnpm"], stubs: ["mise", "npm"])
        XCTAssertFalse(run.result.succeeded)
        XCTAssertTrue(run.result.stderr.contains("kinhin-toolchain install node pnpm"), run.result.stderr)
    }

    // MARK: - Baking

    func testInstallSnippetRoundTripsThroughGzip() async throws {
        let snippet = try RunnerBootstrap.toolchainHelperInstallScript(platform: .linux, mountPath: "/var/kinhin-cache")
        let encoded = try XCTUnwrap(
            snippet.split(separator: "\n").first { $0.hasPrefix("echo ") }?.split(separator: " ").dropFirst().first)
        let archive = workDir.appendingPathComponent("helper.gz")
        try XCTUnwrap(Data(base64Encoded: String(encoded))).write(to: archive)
        let decoded = try await Shell().run(["/usr/bin/gzip", "-dc", archive.path])
        XCTAssertTrue(decoded.succeeded, decoded.stderr)
        XCTAssertEqual(decoded.stdout, ToolchainCatalog.helperScript(for: .linux))
        XCTAssertLessThan(snippet.utf8.count, 64 * 1024, "stays well under Linux's 128 KB per-argument limit")
        XCTAssertFalse(snippet.contains("sudo"), "Linux runner containers run as root")
    }

    func testCRC32MatchesTheStandardCheckValue() {
        XCTAssertEqual(Data.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testVMPrepareBakesTheHelperWithTheAgents() async throws {
        let ssh = FakeSSH()
        try await ImagePreparer(tart: FakeTart(), ssh: ssh).run(
            .init(hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false))
        let agents = try XCTUnwrap(ssh.scripts.first)
        XCTAssertTrue(agents.contains("sudo tee \(RunnerBootstrap.toolchainHelperPath)"), agents)
    }

    func testContainerPrepareBakesTheHelperWithTheAgents() async throws {
        let shell = FakeShell()
        try await ContainerImagePreparer(shell: shell).prepare(
            .init(
                image: "ubuntu:24.04", target: "kinhin-ci-linux", hasGitHubToken: true, hasGiteaToken: false,
                hasGitLabToken: false))
        let agents = try XCTUnwrap(shell.calls.first { $0.contains("exec") && $0.contains("/bin/bash") })
        XCTAssertTrue(agents.joined(separator: " ").contains("| tee \(RunnerBootstrap.toolchainHelperPath)"))
    }

    // MARK: - Harness

    private struct HelperRun {
        let result: ShellResult
        let calls: String
        let githubPath: String
        let githubEnv: String
        let mount: String
    }

    /// Runs the macOS helper with stub installers on PATH that log their argv.
    /// `mise`/`npm`/`brew` stubs succeed except `npm ls` (so installs aren't
    /// skipped); verify commands (`go`, `node`, `pnpm`…) exist as no-op stubs.
    private func runHelper(
        _ args: [String], stubs: [String] = ["mise", "npm", "brew", "corepack", "go", "node", "pnpm"]
    ) async throws -> HelperRun {
        let fm = FileManager.default
        let stubDir = workDir.appendingPathComponent("stub")
        let home = workDir.appendingPathComponent("home")
        let mount = workDir.appendingPathComponent("mount dir")
        let log = workDir.appendingPathComponent("calls.log")
        let githubPath = workDir.appendingPathComponent("github_path")
        let githubEnv = workDir.appendingPathComponent("github_env")
        for dir in [stubDir, home.appendingPathComponent(".local/share/mise/shims"), mount] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for stub in stubs {
            let path = stubDir.appendingPathComponent(stub)
            let body = "#!/bin/bash\necho \"\(stub) $*\" >> '\(log.path)'\n[ \"$1\" = ls ] && exit 1\nexit 0\n"
            try body.write(to: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        let script = workDir.appendingPathComponent("kinhin-toolchain")
        try RunnerBootstrap.toolchainHelperScript(platform: .macOS, mountPath: mount.path)
            .write(to: script, atomically: true, encoding: .utf8)

        let result = try await Shell().run(
            [
                "/usr/bin/env", "-i", "HOME=\(home.path)", "PATH=\(stubDir.path):/usr/bin:/bin",
                "GITHUB_PATH=\(githubPath.path)", "GITHUB_ENV=\(githubEnv.path)", "/bin/bash", script.path,
            ] + args)
        func read(_ url: URL) -> String {
            // Absent until something is written: an empty string is the right reading.
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return HelperRun(
            result: result, calls: read(log), githubPath: read(githubPath), githubEnv: read(githubEnv),
            mount: mount.path)
    }
}
