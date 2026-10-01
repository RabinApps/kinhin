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
            ("Bitbucket", RunnerBootstrap.tartLinuxBitbucketRunnerInstallScript(version: "6.0.8", jdkVersion: "25.0.4.1+1")),
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
            ("Bitbucket", RunnerBootstrap.tartLinuxBitbucketRunnerInstallScript(version: "6.0.8", jdkVersion: "25.0.4.1+1")),
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
