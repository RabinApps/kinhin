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
}
