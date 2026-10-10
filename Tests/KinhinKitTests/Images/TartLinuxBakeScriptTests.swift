import XCTest

@testable import KinhinKit

/// The agent-install scripts baked into a tart Linux base VM (`image
/// prepare` against a Linux guest): Linux binaries, the same `$HOME` layout
/// as the macOS bake (registration needs no changes), and apt prerequisites.
final class TartLinuxBakeScriptTests: XCTestCase {
    func testGitHubAgentInstallsLinuxBinariesInTheHomeLayout() {
        let script = RunnerBootstrap.tartLinuxGitHubAgentInstallScript(runnerVersion: "2.337.0", runnerCount: 2)
        XCTAssertTrue(script.contains("actions-runner-linux-arm64-2.337.0.tar.gz"), script)
        XCTAssertTrue(script.contains("$HOME/actions-runner"), "the macOS registration layout")
        XCTAssertTrue(script.contains("$HOME/actions-runner-2"), "one agent directory per runner")
        XCTAssertTrue(script.contains("installdependencies.sh"), "Linux agents need their deps")
        XCTAssertTrue(script.contains("sha256sum"), "downloads stay digest-verified")
    }

    func testGiteaGitLabAndBuildkiteInstallLinuxBinaries() {
        let gitea = RunnerBootstrap.tartLinuxGiteaRunnerInstallScript(version: "4.0.0")
        XCTAssertTrue(gitea.contains("gitea-runner-4.0.0-linux-arm64.xz"), gitea)
        XCTAssertTrue(gitea.contains("$HOME/gitea-runner"), gitea)

        let gitlab = RunnerBootstrap.tartLinuxGitLabRunnerInstallScript(version: "19.4.1")
        XCTAssertTrue(gitlab.contains("binaries/gitlab-runner-linux-arm64"), gitlab)
        XCTAssertTrue(gitlab.contains("$HOME/gitlab-runner"), gitlab)

        let buildkite = RunnerBootstrap.tartLinuxBuildkiteAgentInstallScript(version: "3.100.0")
        XCTAssertTrue(buildkite.contains("buildkite-agent-linux-arm64-3.100.0.tar.gz"), buildkite)
        XCTAssertTrue(buildkite.contains("$HOME/buildkite-agent"), buildkite)
    }

    func testAzureAgentInstallsTheLinuxBinaryAndItsDependencies() {
        let script = RunnerBootstrap.tartLinuxAzureAgentInstallScript(version: "5.279.0")
        XCTAssertTrue(script.contains("vsts-agent-linux-arm64-5.279.0.tar.gz"), script)
        XCTAssertTrue(script.contains("$HOME/azure-agent"), "the macOS registration layout")
        XCTAssertTrue(script.contains("installdependencies.sh"), "the Linux agent needs ICU and friends")
    }

    /// Runs the Azure bake script as a non-root guest user would: `installdependencies.sh` refuses to run
    /// unprivileged (so it needs the `$SUDO` the prerequisites pick), and the baked agent is smoke-tested.
    func testAzureAgentBakeRunsItsDependencyInstallerPrivilegedAndSmokeTestsTheAgent() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("azure-bake-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        let payload = root.appendingPathComponent("payload/bin")
        let home = root.appendingPathComponent("home")
        for dir in [bin, payload, home] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        func write(_ url: URL, _ body: String) throws {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        // The "agent": a config.sh, the dependency installer and the listener.
        try write(
            root.appendingPathComponent("payload/config.sh"), "#!/bin/bash\nexit 0\n")
        try write(
            payload.appendingPathComponent("installdependencies.sh"),
            """
            #!/bin/bash
            if [ "$(id -u)" -ne 0 ] && [ "${SUDO_STUB:-}" != 1 ]; then echo "need sudo" >&2; exit 1; fi
            echo "installdependencies" >> "$STUB_LOG"
            """)
        try write(
            payload.appendingPathComponent("Agent.Listener"),
            """
            #!/bin/bash
            echo "listener $*" >> "$STUB_LOG"
            exit "${LISTENER_EXIT:-0}"
            """)
        let tarball = root.appendingPathComponent("agent.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["czf", tarball.path, "-C", root.appendingPathComponent("payload").path, "."]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
        let digest = Process()
        digest.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        digest.arguments = ["-a", "256", tarball.path]
        let digestOut = Pipe()
        digest.standardOutput = digestOut
        try digest.run()
        let sum =
            String(decoding: digestOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: " ").first.map(String.init) ?? ""
        digest.waitUntilExit()
        XCTAssertEqual(sum.count, 64)
        // curl serves the release notes row for the digest query and the tarball for the download.
        try write(
            bin.appendingPathComponent("curl"),
            """
            #!/bin/bash
            out=""
            while [ $# -gt 0 ]; do if [ "$1" = -o ]; then out="$2"; fi; shift; done
            if [ -n "$out" ]; then cp "\(tarball.path)" "$out"; else
              echo "| Linux ARM64 | [vsts-agent-linux-arm64-5.279.0.tar.gz](https://x/vsts-agent-linux-arm64-5.279.0.tar.gz) | \(sum) |"
            fi
            """)
        try write(
            bin.appendingPathComponent("sudo"),
            "#!/bin/bash\n[ \"$1\" = -n ] && shift\nexport SUDO_STUB=1\nexec \"$@\"\n")
        try write(bin.appendingPathComponent("apt-get"), "#!/bin/bash\nexit 0\n")

        let script = RunnerBootstrap.tartLinuxAzureAgentInstallScript(version: "5.279.0")
        func run(listenerExit: String?) throws -> (Int32, String, String) {
            let log = root.appendingPathComponent("stub.log")
            try? fm.removeItem(at: log)
            try? fm.removeItem(at: home.appendingPathComponent("azure-agent"))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", script]
            var env = [
                "HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin", "STUB_LOG": log.path,
            ]
            if let listenerExit { env["LISTENER_EXIT"] = listenerExit }
            process.environment = env
            let err = Pipe()
            process.standardError = err
            process.standardOutput = Pipe()
            try process.run()
            let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (
                process.terminationStatus, stderr, (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            )
        }

        let ok = try run(listenerExit: nil)
        XCTAssertEqual(ok.0, 0, ok.1)
        XCTAssertEqual(ok.2, "installdependencies\nlistener --version\n")

        let broken = try run(listenerExit: "1")
        XCTAssertNotEqual(broken.0, 0, "a listener that cannot start fails the bake")
    }

    func testBitbucketRunnerUsesTheLinuxJDKAndTheMacWrapperPath() {
        let script = RunnerBootstrap.tartLinuxBitbucketRunnerInstallScript(version: "6.0.8", jdkVersion: "25.0.4.1+1")
        XCTAssertTrue(script.contains("OpenJDK25U-jdk_aarch64_linux_hotspot_25.0.4.1_1.tar.gz"), script)
        XCTAssertTrue(script.contains("$HOME/bitbucket-runner"), "the macOS registration layout")
        XCTAssertTrue(script.contains("jdk/bin"), "the wrapper puts the JDK on PATH")
    }

    func testEveryScriptKeepsTheSHA256Verification() {
        let scripts: [(String, String)] = [
            ("GitHub", RunnerBootstrap.tartLinuxGitHubAgentInstallScript(runnerVersion: "2.337.0")),
            ("Gitea", RunnerBootstrap.tartLinuxGiteaRunnerInstallScript(version: "4.0.0")),
            ("GitLab", RunnerBootstrap.tartLinuxGitLabRunnerInstallScript(version: "19.4.1")),
            ("Buildkite", RunnerBootstrap.tartLinuxBuildkiteAgentInstallScript(version: "3.100.0")),
            ("Azure", RunnerBootstrap.tartLinuxAzureAgentInstallScript(version: "5.279.0")),
            (
                "Bitbucket",
                RunnerBootstrap.tartLinuxBitbucketRunnerInstallScript(version: "6.0.8", jdkVersion: "25.0.4.1+1")
            ),
        ]
        for (label, script) in scripts {
            XCTAssertTrue(script.contains("sha256sum") || script.contains("shasum"), "\(label) must verify digests")
            XCTAssertTrue(script.contains("mismatch"), "\(label) must abort on mismatch")
        }
    }

    /// The bake targets Debian/Ubuntu guests (the curated Cirrus images are
    /// Ubuntu/Debian); the scripts say apt-get, and detect passwordless sudo
    /// instead of assuming root (containers) or a fixed user (VMs).
    func testPrerequisitesUseAPTThroughPasswordlessSudo() {
        let script = RunnerBootstrap.tartLinuxGitHubAgentInstallScript(runnerVersion: "2.337.0")
        XCTAssertTrue(script.contains("apt-get update"), script)
        XCTAssertTrue(script.contains("sudo -n true"), "the admin user has passwordless sudo")
        XCTAssertFalse(script.contains("brew"), "no Homebrew on a Linux guest")
    }

    /// The scripts must be plain POSIX/bash: the bake pipes them through
    /// `bash -s` over SSH (see SSHExecutor).
    func testScriptsAreValidShell() throws {
        let scripts: [(String, String)] = [
            ("GitHub", RunnerBootstrap.tartLinuxGitHubAgentInstallScript(runnerVersion: "2.337.0", runnerCount: 2)),
            ("Gitea", RunnerBootstrap.tartLinuxGiteaRunnerInstallScript(version: "4.0.0")),
            ("GitLab", RunnerBootstrap.tartLinuxGitLabRunnerInstallScript(version: "19.4.1")),
            ("Buildkite", RunnerBootstrap.tartLinuxBuildkiteAgentInstallScript(version: "3.100.0")),
            ("Azure", RunnerBootstrap.tartLinuxAzureAgentInstallScript(version: "5.279.0")),
            (
                "Bitbucket",
                RunnerBootstrap.tartLinuxBitbucketRunnerInstallScript(version: "6.0.8", jdkVersion: "25.0.4.1+1")
            ),
            ("prepare (linux)", GuestOS.linux.prepareScript()),
        ]
        for (label, script) in scripts {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-n", "-c", script]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(label) script must be valid bash: \(script)")
        }
    }
}
