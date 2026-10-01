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
}
