import XCTest

@testable import KinhinKit

final class RunnerBootstrapQuotingTests: XCTestCase {
    private let hostile = [
        "plain",
        "with space",
        "it's",
        "$(touch /tmp/kinhin-pwned)",
        "`id`",
        "a; rm -rf ~",
        "line1\nline2",
        "''",
    ]

    /// The quoted form must reach a POSIX shell as exactly the original bytes.
    func testShellQuoteRoundTripsThroughSh() throws {
        for value in hostile {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf %s \(RunnerBootstrap.shellQuote(value))"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(String(decoding: output, as: UTF8.self), value, "value: \(value)")
        }
    }

    func testEveryRegistrationScriptQuotesConfigSuppliedValues() {
        let url = "https://github.com/acme/it's"
        let name = "runner $(id)"
        let labels = ["self-hosted", "x y"]
        let scripts = [
            RunnerBootstrap.registrationScript(
                configureURL: url, token: "tok'en", labels: labels, ephemeral: true, name: name),
            RunnerBootstrap.registrationScript(
                configureURL: url, token: "tok'en", labels: labels, ephemeral: true, name: name, runnerCount: 2),
            RunnerBootstrap.linuxGitHubRegistrationScript(
                configureURL: url, token: "tok'en", labels: labels, ephemeral: true, name: name),
            RunnerBootstrap.giteaRegistrationScript(instance: url, token: "tok'en", labels: labels, name: name),
            RunnerBootstrap.linuxGiteaRegistrationScript(instance: url, token: "tok'en", labels: labels, name: name),
        ]
        for script in scripts {
            XCTAssertTrue(script.contains(RunnerBootstrap.shellQuote("tok'en")), script)
            XCTAssertTrue(script.contains(RunnerBootstrap.shellQuote(url)), script)
            XCTAssertTrue(script.contains(RunnerBootstrap.shellQuote("self-hosted,x y")), script)
            XCTAssertFalse(script.contains("--token 'tok'en'"), "unescaped quote in token")
            XCTAssertFalse(script.contains("--name runner $(id)"), "unquoted name")
        }
    }

    /// Registering again first stops a leftover agent, and the bracketed pattern cannot match the script's own
    /// command line (a VM may receive the script as `bash -c`).
    func testLinuxRegistrationStopsALeftoverAgentWithoutMatchingItself() {
        let github = RunnerBootstrap.linuxGitHubRegistrationScript(
            configureURL: "https://github.com/acme/r", token: "t", labels: ["x"], ephemeral: false, name: "vm")
        let gitea = RunnerBootstrap.linuxGiteaRegistrationScript(
            instance: "https://gitea.example", token: "t", labels: ["x"], name: "vm")
        XCTAssertTrue(github.contains("stop_agent '/bin/[R]unner.Listener'"), github)
        XCTAssertTrue(gitea.contains("stop_agent '[g]itea-runner daemon'"), gitea)
        XCTAssertFalse(github.contains("pkill"))
        XCTAssertFalse(gitea.contains("pkill"))
    }

    /// The helper is valid bash and succeeds when no process matches.
    func testStopLeftoverAgentSucceedsWhenNothingMatches() throws {
        let script = RunnerBootstrap.stopLeftoverAgentScript(pattern: "[n]o-such-agent-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "set -euo pipefail\n" + script]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    /// The helper terminates a process whose command line matches. Needs `/proc`, so it runs on Linux only.
    func testStopLeftoverAgentTerminatesAMatchingProcess() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/proc/self"), "needs /proc")
        let marker = String(Int.random(in: 100_000_000...999_999_999))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = [marker]
        try child.run()
        defer { if child.isRunning { child.terminate() } }

        let script = RunnerBootstrap.stopLeftoverAgentScript(pattern: "[s]leep \(marker)")
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = ["-c", "set -euo pipefail\n" + script]
        try helper.run()
        helper.waitUntilExit()

        XCTAssertEqual(helper.terminationStatus, 0)
        child.waitUntilExit()
        XCTAssertFalse(child.isRunning, "the matching process is stopped")
    }

    /// A quoted `~` is never expanded: the template copy for runners 2..N must
    /// name `"$HOME"/…`, or the copy fails and every extra runner re-downloads.
    func testJitTemplateCopyExpandsHome() {
        let script = RunnerBootstrap.jitRegistrationScript(
            encodedJitConfig: "abc", name: "vm", agentDirectory: "~/actions-runner-2",
            agentTemplate: "~/actions-runner")
        XCTAssertTrue(script.contains("cp -a \"$HOME\"/'actions-runner/.' \"$agent_dir/\""), script)
        XCTAssertTrue(script.contains("agent_dir=\"$HOME\"/'actions-runner-2'"), script)
        XCTAssertFalse(script.contains("'~/"), "a quoted tilde names a literal ~ directory")
    }

    /// The word evaluates to the expanded path in a real shell, and
    /// metacharacters after `~/` stay inert.
    func testGuestPathWordExpandsHomeInBash() throws {
        let word = RunnerBootstrap.guestPathWord("~/runner $(echo pwned)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "printf %s \(word)"]
        process.environment = ["HOME": "/home/ci"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(output, "/home/ci/runner $(echo pwned)")
        XCTAssertEqual(RunnerBootstrap.guestPathWord("/opt/runner"), "'/opt/runner'")
    }
}
