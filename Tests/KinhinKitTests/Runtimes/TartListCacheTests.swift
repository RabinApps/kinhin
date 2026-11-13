import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// `tart list` probes every VM's disk image (and on macOS 27.2 leaks kernel APFS objects per probe),
/// so callers share one listing for a short while instead of each running their own.
final class TartListCacheTests: XCTestCase {
    private static let listing = """
        [{"State":"running","Disk":50,"Source":"local","Size":40,"Name":"kinhin-1-a","Running":true}]
        """

    private func controller(maxAge: Duration = .seconds(60)) throws -> (TartController, FakeShell) {
        let shell = FakeShell()
        shell.scriptedResponses = [
            ScriptedResponse(
                whenContainsAll: ["list", "--format"], ShellResult(exitCode: 0, stdout: Self.listing, stderr: ""))
        ]
        var tart = try TartController(configuredPath: "/bin/sh", shell: shell, softnet: false)
        tart.listCache = TartListCache(maxAge: maxAge)
        return (tart, shell)
    }

    private func listCalls(_ shell: FakeShell) -> Int {
        shell.calls.filter { $0.contains("list") }.count
    }

    func testFreshListingIsShared() async throws {
        let (tart, shell) = try controller()
        _ = try await tart.list()
        let vms = try await tart.list()
        XCTAssertEqual(vms.map(\.name), ["kinhin-1-a"])
        XCTAssertEqual(listCalls(shell), 1, "the second caller reads the first listing")
    }

    func testExpiredListingRunsTartAgain() async throws {
        let (tart, shell) = try controller(maxAge: .zero)
        _ = try await tart.list()
        _ = try await tart.list()
        XCTAssertEqual(listCalls(shell), 2)
    }

    func testConcurrentCallersShareOneListing() async throws {
        let cache = TartListCache(maxAge: .seconds(60))
        let fetches = Locked(0)
        try await withThrowingTaskGroup(of: [TartVM].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await cache.list {
                        fetches.withLock { $0 += 1 }
                        try await Task.sleep(for: .milliseconds(100))
                        return [TartVM(name: "vm", source: "local", status: "running")]
                    }
                }
            }
            for try await vms in group { XCTAssertEqual(vms.map(\.name), ["vm"]) }
        }
        XCTAssertEqual(fetches.withLock { $0 }, 1)
    }

    func testChangesThroughTheControllerInvalidate() async throws {
        let (tart, shell) = try controller()
        _ = try await tart.list()
        try await tart.stop(name: "kinhin-1-a")
        _ = try await tart.list()
        try await tart.clone(source: "base", to: "kinhin-2-b")
        _ = try await tart.list()
        try await tart.delete(name: "kinhin-2-b")
        _ = try await tart.list()
        XCTAssertEqual(listCalls(shell), 4, "every change made through kinhin forces a new listing")
    }

    func testFailedListingIsNotCached() async throws {
        let cache = TartListCache(maxAge: .seconds(60))
        let attempts = Locked(0)
        let fetch: @Sendable () async throws -> [TartVM] = {
            let n = attempts.withLock { count -> Int in
                count += 1
                return count
            }
            if n == 1 { throw TartError.commandFailed(what: "list", stderr: "boom") }
            return []
        }
        do {
            _ = try await cache.list(fetch: fetch)
            XCTFail("the first listing fails")
        } catch {}
        _ = try await cache.list(fetch: fetch)
        XCTAssertEqual(attempts.withLock { $0 }, 2)
    }

    func testListingStartedBeforeAChangeIsNotStoredOrReturned() async throws {
        let cache = TartListCache(maxAge: .seconds(60))
        let fetches = Locked(0)
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let fetch: @Sendable () async throws -> [TartVM] = {
            let n = fetches.withLock { count -> Int in
                count += 1
                return count
            }
            startedSignal.yield()
            try await Task.sleep(for: .milliseconds(100))
            return [TartVM(name: "listing-\(n)", source: "local", status: "running")]
        }
        async let first = cache.list(fetch: fetch)
        var signals = started.makeAsyncIterator()
        _ = await signals.next()  // the first listing is in flight
        cache.invalidate()
        let waited = try await first
        XCTAssertEqual(waited.map(\.name), ["listing-2"], "a caller waiting across a change lists again")
        let later = try await cache.list(fetch: fetch)
        XCTAssertEqual(later.map(\.name), ["listing-2"], "the listing after the change is the one stored")
        XCTAssertEqual(fetches.withLock { $0 }, 2)
    }

    func testInjectedShellsAreNotCachedByDefault() throws {
        let tart = try TartController(configuredPath: "/bin/sh", shell: FakeShell(), softnet: false)
        XCTAssertNil(tart.listCache)
    }

    func testRealShellsShareOneCachePerBinary() throws {
        let a = try TartController(configuredPath: "/bin/sh")
        let b = try TartController(configuredPath: "/bin/sh")
        XCTAssertTrue(a.listCache === b.listCache)
    }
}
