import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class LinuxPrerequisitesTests: XCTestCase {
    private var scripts: [(name: String, script: String)] {
        [
            ("github agent", RunnerBootstrap.linuxGitHubAgentInstallScript(runnerVersion: "2.337.0")),
            ("gitea runner", RunnerBootstrap.linuxGiteaRunnerInstallScript(version: "0.2.0")),
            (
                "toolchains",
                RunnerBootstrap.linuxManagedToolchainsInstallScript(
                    selection: ManagedToolchainSelection(), mountPath: nil)
            ),
        ]
    }

    func testEveryScriptInstallsCurlAndCertificatesBeforeDownloading() {
        for (name, script) in scripts {
            let prerequisites = script.range(of: "apt-get install -y --no-install-recommends $need")
            XCTAssertNotNil(prerequisites, "\(name) must install its prerequisites")
            XCTAssertTrue(script.contains("command -v curl"), "\(name) must check for curl")
            XCTAssertTrue(script.contains("ca-certificates"), "\(name) must ensure CA certificates")
            if let prerequisites, let download = script.range(of: "curl -") {
                XCTAssertLessThan(prerequisites.lowerBound, download.lowerBound, "\(name): install before curl runs")
            }
        }
        XCTAssertTrue(scripts[1].script.contains("xz-utils"), "the gitea runner ships as .xz")
    }

    func testScriptsAreValidBashSyntax() async throws {
        for (name, script) in scripts {
            let result = try await Shell().run(["/bin/bash", "-n", "-c", script], cwd: nil, timeout: 10)
            XCTAssertTrue(result.succeeded, "\(name): \(result.stderr)")
        }
    }

    func testPrerequisitesAreANoOpWhenEverythingIsPresent() async throws {
        // `true`, `sh`, and `ls` exist everywhere; with the certificate check
        // satisfied the script must not touch apt.
        let script = RunnerBootstrap.linuxPrerequisitesScript(tools: [("sh", "dash"), ("ls", "coreutils")])
            .replacingOccurrences(of: "/etc/ssl/certs/ca-certificates.crt", with: "/etc/hosts")
            .replacingOccurrences(of: "apt-get", with: "false-apt-get-should-not-run")
        let result = try await Shell().run(["/bin/bash", "-c", script], cwd: nil, timeout: 10)
        XCTAssertTrue(result.succeeded, result.stderr)
    }
}
