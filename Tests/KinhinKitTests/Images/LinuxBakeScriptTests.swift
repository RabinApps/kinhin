import XCTest

@testable import KinhinKit

/// The container bake (`kinhin image prepare --docker/--container`) hands the
/// guest a bash script, so everything that must expand *there* — brace ranges,
/// `$index` — has to be spelled so bash expands it and Swift does not.
final class LinuxBakeScriptTests: XCTestCase {
    func testTheDensityCopyLoopIsWrittenForBash() {
        let script = RunnerBootstrap.linuxGitHubAgentInstallScript(version: "2.337.0")
        XCTAssertTrue(script.contains("for index in {2..10}; do"), "bash ranges are {2..10}: \\(script)")
        XCTAssertTrue(script.contains("/opt/actions-runner-$index"), "bash needs the variable: \\(script)")
        XCTAssertFalse(script.contains("2...10"), "bash has no 2...10 range: \\(script)")
        XCTAssertFalse(script.contains("(Function)"), "Swift interpolated Darwin's index(): \\(script)")
    }

    /// The bake execs with the base image's WORKDIR (ubuntu's `/`), so each
    /// tarball must be extracted *inside* its `/opt` directory. The GitHub
    /// script used to extract at `/`: the runner's `bin/` replaced the
    /// usr-merge `/bin` symlink, and the committed image had no `/bin/sh` —
    /// it could not start a container at all.
    func testEveryAgentIsDownloadedInsideItsOptDirectory() throws {
        let scripts: [(String, String)] = [
            ("GitHub", RunnerBootstrap.linuxGitHubAgentInstallScript(version: "2.337.0")),
            ("Gitea", RunnerBootstrap.linuxGiteaRunnerInstallScript(version: "0.2.0")),
            ("GitLab", RunnerBootstrap.linuxGitLabRunnerInstallScript(version: "19.4.1")),
            ("Buildkite", RunnerBootstrap.linuxBuildkiteAgentInstallScript(version: "3.100.0")),
            ("Azure", RunnerBootstrap.linuxAzureAgentInstallScript(version: "5.279.0")),
            (
                "Bitbucket",
                RunnerBootstrap.linuxBitbucketRunnerInstallScript(version: "6.0.8", jdkVersion: "25.0.4.1+1")
            ),
        ]
        for (label, script) in scripts {
            let cd = try XCTUnwrap(script.range(of: "cd /opt/"), "\(label): no cd into its install directory")
            let download = try XCTUnwrap(script.range(of: "curl --proto-redir"), "\(label): no verified download")
            XCTAssertLessThan(
                cd.lowerBound, download.lowerBound,
                "\(label): the download must land inside /opt, not in the image's WORKDIR")
        }
    }

    /// Runs the loop itself (paths redirected into a temp root): the baked
    /// image must hold the template plus copies `-2` … `-10`, which
    /// registration for `runners_per_vm > 1` copies from.
    func testTheCopyLoopMaterializesRunner2Through10() async throws {
        let script = RunnerBootstrap.linuxGitHubAgentInstallScript(version: "2.337.0")
        let lines = script.split(separator: "\n").map(String.init)
        let start = try XCTUnwrap(lines.firstIndex { $0.contains("for index in") }, "copy loop not found")
        let end = try XCTUnwrap(lines[start...].firstIndex { $0.trimmingCharacters(in: .whitespaces) == "done" })

        let opt = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-bake-\(UUID().uuidString)")
        let template = opt.appendingPathComponent("actions-runner")
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: opt) }
        try "template".write(to: template.appendingPathComponent("config.sh"), atomically: true, encoding: .utf8)

        let loop = lines[start...end].joined(separator: "\n")
            .replacingOccurrences(of: "/opt/actions-runner", with: template.path)
        let result = try await Shell().run(["/bin/bash", "-c", loop], cwd: nil, timeout: 30)
        XCTAssertTrue(result.succeeded, result.stderr)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: template.path + "-(Function)"),
            "the old Swift interpolation baked this directory")
        for index in 2...10 {
            let copy = opt.appendingPathComponent("actions-runner-\(index)/config.sh")
            XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "missing copy \\(index)")
        }
    }
}
