import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class DeleteVMValidationTests: XCTestCase {
    private func makeEngine(tart: FakeTart, github: FakeGitHub) -> FleetEngine {
        FleetEngine(
            config: makeTestConfig(), github: github, tart: tart, store: makeTestStore(), ssh: FakeSSH(),
            host: testHost,
            dependencies: .init(hostProbe: {
                HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 500, arm64: true)
            }))
    }

    func testDeleteRejectsIdsThatAreNotInTheStoreAndTouchesNothing() async {
        let tart = FakeTart()
        let github = FakeGitHub()
        let engine = makeEngine(tart: tart, github: github)
        for id in ["tahoe-base", "kinhin-not-ours", "../kinhin-1", "", "kinhin-1;id"] {
            do {
                try await engine.deleteVM(id: id)
                XCTFail("'\(id)' must be rejected")
            } catch {
                guard case EngineError.unknownVM(let rejected)? = error as? EngineError else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertEqual(rejected, id)
            }
        }
        XCTAssertTrue(tart.stopCalls.isEmpty)
        XCTAssertTrue(tart.deleteCalls.isEmpty)
    }
}
