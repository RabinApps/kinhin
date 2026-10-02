import Foundation
import Synchronization
import XCTest

@testable import KinhinKit

/// Scratch-directory fleet store for tests.
func makeTestStore() -> FleetStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("kinhin-tests-\(UUID().uuidString)", isDirectory: true)
    // Best-effort: if the scratch dir can't be created, the store fails on first use.
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return FleetStore(directory: dir)
}

func makeTestConfig(repo: String = "acme/widgets") -> KinhinConfig {
    var cfg = KinhinConfig.default
    cfg.accounts = [AccountConfig(name: "github", forge: .github, scope: repo)]
    cfg.labels = ["kinhin"]
    cfg.pollInterval = 5
    cfg.vmBootTimeout = 30
    return cfg
}

let testHost = HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true)

extension XCTestCase {
    /// Polls until `condition` holds (a spawned lifecycle runs on its own
    /// task, so a reconcile pass returns before its clone/ssh calls happen).
    func waitForCondition(timeout: TimeInterval = 10, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}
