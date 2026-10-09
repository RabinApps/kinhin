import XCTest

@testable import KinhinKit

/// With several runners on one VM, a started runner is already executing job
/// code while `config.sh --token` for the next one would still be running, with
/// the registration token visible in `ps`. So every runner registers first.
final class MultiRunnerRegistrationOrderTests: XCTestCase {
    func testAllRunnersAreRegisteredBeforeAnyIsStarted() throws {
        let script = RunnerBootstrap.registrationScript(
            configureURL: "https://github.com/acme/widgets", token: "TOKEN", labels: ["x"], ephemeral: true,
            name: "kinhin-1", runnerCount: 3)
        let lines = script.split(separator: "\n").map(String.init)
        let lastConfigure = try XCTUnwrap(lines.lastIndex { $0.contains("./config.sh --url") })
        let firstStart = try XCTUnwrap(lines.firstIndex { $0.contains("nohup ./run.sh") })
        XCTAssertLessThan(lastConfigure, firstStart, "no runner may start before the last one is registered")
        XCTAssertEqual(lines.filter { $0.contains("nohup ./run.sh") }.count, 3)
        XCTAssertEqual(lines.filter { $0.contains("./config.sh --url") }.count, 3)
    }

    /// Gitea's runner is not the actions-runner: each runner registers in its own `run-N` directory (`register`
    /// writes `.runner` into the working directory) and its daemon starts only after that runner's registration.
    /// The macOS VM script and the Linux/container script are the same flow, differing in the agent directory.
    func testGiteaRunnersRegisterBeforeTheyStart() throws {
        let mac = RunnerBootstrap.giteaRegistrationScript(
            instance: "https://gitea.example", token: "TOKEN", labels: ["x"], name: "kinhin-1", runnerCount: 3)
        let linux = RunnerBootstrap.linuxGiteaRegistrationScript(
            instance: "https://gitea.example", token: "TOKEN", labels: ["x"], name: "kinhin-1", runnerCount: 3)
        for script in [mac, linux] {
            let lines = script.split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.filter { $0.contains("gitea-runner\" register") }.count, 3)
            XCTAssertEqual(lines.filter { $0.contains("gitea-runner\" daemon") }.count, 3)
            let starts = lines.indices.filter { lines[$0].contains("gitea-runner\" daemon") }
            for start in starts {
                let opened = try XCTUnwrap(lines[..<start].lastIndex { $0.hasPrefix("cd \"") })
                let registered = try XCTUnwrap(
                    lines[opened..<start].firstIndex { $0.contains("gitea-runner\" register") })
                XCTAssertLessThan(opened, registered)
            }
        }
    }
}
