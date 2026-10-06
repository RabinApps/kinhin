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

    /// Gitea's two scripts follow their own contracts, both pinned elsewhere:
    /// macOS registers a single runner (multi-runner Gitea is a follow-up —
    /// ForgeTests pins the one-daemon shape) and registers before starting;
    /// Linux registers each runner in its own `/opt/actions-runner-N` directory
    /// with the actions-runner `config.sh` the image bake provides (see
    /// DockerRuntimeTests) and starts it with `run.sh` only after that
    /// runner's registration completed.
    func testGiteaRunnersRegisterBeforeTheyStart() throws {
        let mac = RunnerBootstrap.giteaRegistrationScript(
            instance: "https://gitea.example", token: "TOKEN", labels: ["x"], name: "kinhin-1", runnerCount: 3)
        let macLines = mac.split(separator: "\n").map(String.init)
        let macRegister = try XCTUnwrap(macLines.lastIndex { $0.contains("gitea-runner register") })
        let macStart = try XCTUnwrap(macLines.firstIndex { $0.contains("nohup ./gitea-runner run") })
        XCTAssertLessThan(macRegister, macStart, "the runner registers before it starts")
        XCTAssertEqual(macLines.filter { $0.contains("gitea-runner register") }.count, 1)
        XCTAssertEqual(macLines.filter { $0.contains("nohup ./gitea-runner run") }.count, 1)

        let linux = RunnerBootstrap.linuxGiteaRegistrationScript(
            instance: "https://gitea.example", token: "TOKEN", labels: ["x"], name: "kinhin-1", runnerCount: 3)
        let lines = linux.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.filter { $0.contains("./config.sh --url") }.count, 3)
        XCTAssertEqual(lines.filter { $0.contains("nohup ./run.sh") }.count, 3)
        // Every start shares its block with its own registration: the nearest
        // preceding `cd` opens that runner's directory, and that runner's
        // config.sh follows the cd before anything is started from it.
        let starts = lines.indices.filter { lines[$0].contains("nohup ./run.sh") }
        for start in starts {
            let opened = try XCTUnwrap(lines[..<start].lastIndex { $0.hasPrefix("cd \"") })
            let registered = try XCTUnwrap(lines[opened..<start].firstIndex { $0.contains("./config.sh --url") })
            XCTAssertLessThan(opened, registered)
        }
    }
}
