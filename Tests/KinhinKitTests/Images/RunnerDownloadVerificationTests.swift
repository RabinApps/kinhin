import CryptoKit
import XCTest

@testable import KinhinKit

final class RunnerDownloadVerificationTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs the generated download script with `file://` URLs and reports
    /// the exit status, stderr, and whether the download was kept.
    private func run(served: Data, publishedDigest: String) throws -> (status: Int32, stderr: String, kept: Bool) {
        let source = dir.appendingPathComponent("served.bin")
        try served.write(to: source)
        let digestFile = dir.appendingPathComponent("digest.txt")
        try publishedDigest.write(to: digestFile, atomically: true, encoding: .utf8)
        let script = RunnerBootstrap.verifiedDownloadScript(
            url: source.absoluteString, file: "runner.bin",
            expectedDigestCommand: "cat \(RunnerBootstrap.shellQuote(digestFile.path))")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "set -euo pipefail\ncd \(RunnerBootstrap.shellQuote(dir.path))\n" + script]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus, String(decoding: err, as: UTF8.self),
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("runner.bin").path)
        )
    }

    func testMatchingDigestKeepsTheDownload() throws {
        let payload = Data("genuine runner".utf8)
        let result = try run(served: payload, publishedDigest: hex(payload))
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.kept)
    }

    func testMismatchAbortsAndDeletesTheDownload() throws {
        let result = try run(served: Data("tampered".utf8), publishedDigest: hex(Data("genuine".utf8)))
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("mismatch"), result.stderr)
        XCTAssertFalse(result.kept, "an unverified agent must not stay on disk")
    }

    func testMissingPublishedDigestFailsClosed() throws {
        let result = try run(served: Data("anything".utf8), publishedDigest: "")
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("could not determine"), result.stderr)
        XCTAssertFalse(result.kept)
    }

    func testEveryAgentInstallScriptVerifiesItsDownload() {
        let scripts: [(String, String)] = [
            ("macOS GitHub", RunnerBootstrap.installScript(runnerVersion: "2.337.0", runnerCount: 2)),
            ("macOS Gitea", RunnerBootstrap.giteaRunnerInstallScript(version: "4.0.0")),
            ("Linux GitHub", RunnerBootstrap.linuxGitHubAgentInstallScript(version: "2.337.0", arch: "x64")),
            ("Linux Gitea", RunnerBootstrap.linuxGiteaRunnerInstallScript(version: "4.0.0", arch: "amd64")),
            ("macOS GitLab", RunnerBootstrap.gitlabRunnerInstallScript(version: "19.4.1")),
            ("Linux GitLab", RunnerBootstrap.linuxGitLabRunnerInstallScript(version: "19.4.1", arch: "amd64")),
        ]
        for (label, script) in scripts {
            XCTAssertTrue(script.contains("sha256sum"), "\(label) must verify a SHA-256")
            XCTAssertTrue(script.contains("mismatch"), "\(label) must abort on mismatch")
            XCTAssertFalse(script.contains("curl -sL"), "\(label) still has an unchecked, non-failing download")
            XCTAssertEqual(shellSyntaxStatus(script), 0, "\(label) script must be valid shell")
        }
    }

    func testDigestSourcesMatchTheVendorPlatformNames() {
        let github = RunnerBootstrap.githubRunnerDigestCommand(version: "2.337.0", platform: "linux-x64")
        XCTAssertTrue(github.contains("releases/tags/v2.337.0"))
        XCTAssertTrue(github.contains("BEGIN SHA linux-x64 -->"))
        let gitea = RunnerBootstrap.giteaRunnerDownloadScript(version: "4.0.0", platform: "linux-amd64", file: "r.xz")
        XCTAssertTrue(gitea.contains("gitea-runner-4.0.0-linux-amd64.xz.sha256"))
        let gitlab = RunnerBootstrap.gitlabRunnerDownloadScript(version: "19.4.1", platform: "darwin-arm64", file: "g")
        XCTAssertTrue(gitlab.contains("/v19.4.1/binaries/gitlab-runner-darwin-arm64'"))
        XCTAssertTrue(gitlab.contains("/v19.4.1/release.sha256"))
        XCTAssertTrue(gitlab.contains("-v a='binaries/gitlab-runner-darwin-arm64'"))
    }

    /// The digest pipeline picks the right line out of GitLab's checksum file
    /// (tab-separated, optionally "*"- or "./"-prefixed names).
    func testGitLabDigestPipelineSelectsTheAssetLine() throws {
        let command = RunnerBootstrap.gitlabRunnerDigestCommand(version: "1.0.0", platform: "darwin-arm64")
        let awk = try XCTUnwrap(command.range(of: "awk ")).lowerBound
        let pipeline = String(command[awk...])
        let sums =
            "aaa\tbinaries/gitlab-runner-darwin-amd64\nbbb\t*binaries/gitlab-runner-darwin-arm64\n"
            + "ccc\tbinaries/gitlab-runner-darwin-arm64.exe\n"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '\(sums)' | \(pipeline)"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        let digest = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(digest.trimmingCharacters(in: .whitespacesAndNewlines), "bbb")
    }

    /// Buildkite's SHA256SUMS may name archives `*name` or `./name`.
    func testBuildkiteDigestPipelineStripsNamePrefixes() throws {
        let command = RunnerBootstrap.buildkiteAgentDigestCommand(
            version: "3.100.0", asset: "buildkite-agent-darwin-arm64-3.100.0.tar.gz")
        let pipeline = String(command[try XCTUnwrap(command.range(of: "awk ")).lowerBound...])
        let sums =
            "aaa  buildkite-agent-linux-arm64-3.100.0.tar.gz\nbbb  ./buildkite-agent-darwin-arm64-3.100.0.tar.gz\n"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '\(sums)' | \(pipeline)"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        let digest = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(digest.trimmingCharacters(in: .whitespacesAndNewlines), "bbb")
    }

    private func shellSyntaxStatus(_ script: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", script]
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
