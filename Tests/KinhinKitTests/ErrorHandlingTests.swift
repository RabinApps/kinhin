import XCTest

@testable import KinhinKit

/// Behavior of the shared error-handling helpers and the paths that stopped
/// swallowing failures.
final class ErrorHandlingTests: XCTestCase {
    private struct Boom: Error, LocalizedError {
        var errorDescription: String? { "boom" }
    }

    // MARK: bestEffort

    func testBestEffortSwallowsButLogsFailure() async {
        let marker = "best-effort-\(UUID().uuidString)"
        await bestEffortAsync("test", marker) { throw Boom() }
        XCTAssertTrue(Log.snapshot(limit: 50).contains { $0.message.contains(marker) && $0.message.contains("boom") })
    }

    func testBestEffortDoesNotLogCancellation() async {
        let marker = "cancelled-\(UUID().uuidString)"
        await bestEffortAsync("test", marker) { throw CancellationError() }
        XCTAssertFalse(Log.snapshot(limit: 50).contains { $0.message.contains(marker) })
    }

    // MARK: withTransientRetry

    func testRetryRecoversFromTransientFailure() async throws {
        var calls = 0
        let value = try await withTransientRetry(baseDelay: 0.001, isTransient: { _ in true }) {
            calls += 1
            if calls < 3 { throw Boom() }
            return "ok"
        }
        XCTAssertEqual(value, "ok")
        XCTAssertEqual(calls, 3)
    }

    func testRetryGivesUpAndRethrowsLastError() async {
        var calls = 0
        do {
            _ = try await withTransientRetry(retries: 2, baseDelay: 0.001, isTransient: { _ in true }) {
                calls += 1
                throw Boom()
            }
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error is Boom)
        }
        XCTAssertEqual(calls, 3, "one attempt plus two retries")
    }

    func testRetrySkipsNonTransientErrors() async {
        var calls = 0
        do {
            _ = try await withTransientRetry(baseDelay: 0.001, isTransient: { _ in false }) {
                calls += 1
                throw Boom()
            }
            XCTFail("expected a throw")
        } catch {}
        XCTAssertEqual(calls, 1)
    }

    func testGiteaTransientClassification() {
        XCTAssertTrue(GiteaClient.isTransient(GiteaError.http(503, "")))
        XCTAssertTrue(GiteaClient.isTransient(GiteaError.http(0, "non-HTTP response")))
        XCTAssertTrue(GiteaClient.isTransient(URLError(.timedOut)))
        XCTAssertFalse(GiteaClient.isTransient(GiteaError.http(400, "")))
        XCTAssertFalse(GiteaClient.isTransient(GiteaError.unauthorized))
        XCTAssertFalse(GiteaClient.isTransient(GiteaError.notFound("x")))
    }

    // MARK: Tart runtime

    func testTartProvisionSurfacesListFailureInsteadOfCloningBlind() async {
        let tart = FakeTart()
        tart.failList = true
        let runtime = TartRuntime(tart: tart, bootTimeout: { 300 })
        do {
            try await runtime.provision(
                id: "vm-1", route: RepoRoute(repo: "acme/widgets", image: "base", ephemeral: true, bootTimeout: 300))
            XCTFail("a failed VM listing must not be treated as an empty list")
        } catch {
            XCTAssertTrue(error is TartError)
        }
        XCTAssertTrue(tart.cloneCalls.isEmpty)
    }

    func testTartTeardownStillAttemptsDeleteWhenListFails() async {
        let tart = FakeTart()
        tart.vms["vm-1"] = TartVM(name: "vm-1", source: "base", status: "running")
        tart.failList = true
        let runtime = TartRuntime(tart: tart, bootTimeout: { 300 })
        await runtime.teardown(id: "vm-1")
        XCTAssertEqual(tart.deleteCalls, ["vm-1"])
    }

    func testTartExistingInstanceIDsIsEmptyWhenListFails() async {
        let tart = FakeTart()
        tart.failList = true
        let ids = await TartRuntime(tart: tart, bootTimeout: { 300 }).existingInstanceIDs()
        XCTAssertEqual(ids, [])
    }

    // MARK: Config edit errors

    func testConfigEditErrorMessages() {
        XCTAssertEqual(ConfigEditError.notFound("/x").errorDescription, "config not found at /x")
        XCTAssertEqual(ConfigEditError.validation("bad").errorDescription, "bad")
        XCTAssertTrue(ConfigEditError.rejected("bad").errorDescription?.hasPrefix("config validation failed") == true)
    }

    // MARK: Paths

    func testSupportDirectoriesResolveWithoutTrapping() {
        XCTAssertEqual(Paths.appSupport.lastPathComponent, "Kinhin")
        XCTAssertTrue(Paths.legacyAppSupport.path.hasSuffix("/Orchard"))
        XCTAssertTrue(Daemon.agentPlistPath().path.contains("LaunchAgents"))
    }
}
