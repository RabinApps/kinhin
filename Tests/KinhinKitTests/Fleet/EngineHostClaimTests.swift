import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// One engine per host: an engine that cannot claim the host's lock must not start, or two engines with separate
/// stores would tear down each other's instances as orphans.
final class EngineHostClaimTests: XCTestCase {
    let host = HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true)

    private func makeEngine(
        claimHost: (@Sendable () throws -> Void)?, tart: FakeTart = FakeTart(), store: FleetStore? = nil
    ) throws -> FleetEngine {
        let config = try ConfigLoader.parse(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: ["kinhin"]
            image: "tahoe-base"
            """)
        var deps = FleetEngine.Dependencies(tokenLoader: { _, _ in "test-token" })
        deps.claimHost = claimHost
        return FleetEngine(
            config: config, github: FakeGitHub(), tart: tart, store: store ?? makeTestStore(), ssh: FakeSSH(),
            host: host,
            dependencies: deps)
    }

    func testEngineRefusesToStartWhenAnotherProcessOwnsTheHost() async throws {
        let engine = try makeEngine(claimHost: { throw Daemon.DaemonError.alreadyRunning })
        engine.markRunning()
        let started = await engine.prepareStart()
        XCTAssertFalse(started)
        let status = await engine.status()
        XCTAssertFalse(status.running)
        XCTAssertTrue(status.lastError?.contains("already owns") == true, status.lastError ?? "nil")
    }

    func testStopOnARefusedEngineLeavesTheOwnersInstancesAlone() async throws {
        let tart = FakeTart()
        tart.vms["kinhin-live"] = TartVM(name: "kinhin-live", source: "tahoe-base", status: "running")
        let store = makeTestStore()
        store.upsert(VMRecord(id: "kinhin-live", phase: .ready))
        let engine = try makeEngine(claimHost: { throw Daemon.DaemonError.alreadyRunning }, tart: tart, store: store)
        await engine.start()
        await engine.stop()
        XCTAssertEqual(store.all.map(\.id), ["kinhin-live"], "the owner's record must survive")
        XCTAssertNotNil(tart.vms["kinhin-live"], "the owner's VM must survive")
    }

    func testEngineStartsWhenTheHostClaimSucceeds() async throws {
        let claimed = Locked(0)
        let engine = try makeEngine(claimHost: { claimed.withLock { $0 += 1 } })
        engine.markRunning()
        let started = await engine.prepareStart()
        XCTAssertTrue(started)
        XCTAssertEqual(claimed.withLock { $0 }, 1)
    }

    func testHoldingTheProcessLockTwiceInOneProcessSucceeds() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-claim-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: url) }
        try DaemonLock.holdForProcess(at: url)
        XCTAssertNoThrow(
            try DaemonLock.holdForProcess(at: url), "a rebuilt engine in the owning process must not conflict")
    }
}
