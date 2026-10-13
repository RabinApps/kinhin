import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Contract for `FakeGitHub` as a `GitHubServing`: for the cases the engine
/// tests rely on it must answer like the real `GitHubClient` — the same
/// `GitHubError` cases for token failures, the same configure URL, queued
/// jobs that satisfy the real label-superset filter, runners disappearing
/// from the list after a delete, `nil` for an absent `.kinhin.yml`, and
/// `true` for an accepted cancel/skip. The real side is a `GitHubClient`
/// over `StubProtocol`; no network is involved.
final class FakeGitHubContractTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func makeReal() -> GitHubClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return GitHubClient(
            credentials: GitHubCredentials(token: "test-token", scope: "acme/widgets"),
            session: URLSession(configuration: config)
        )
    }

    /// The first error `op` throws (nil when it succeeds).
    private func firstError(_ op: () async throws -> Void) async -> Error? {
        do {
            try await op()
            return nil
        } catch {
            return error
        }
    }

    /// A comparable label for a `GitHubError` case (the payloads — paths,
    /// messages — legitimately differ between the real client and the fake).
    private func caseLabel(_ error: GitHubError) -> String {
        switch error {
        case .unauthorized: return "unauthorized"
        case .forbidden: return "forbidden"
        case .notFound: return "notFound"
        case .rateLimited: return "rateLimited"
        case .http(let code, _): return "http(\(code))"
        case .decoding: return "decoding"
        case .invalidInstance: return "invalidInstance"
        }
    }

    private func assertSameCase(
        _ real: Error?, _ fake: Error?, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let real = real as? GitHubError else {
            return XCTFail(
                "real client did not throw a GitHubError: \(String(describing: real)) — \(label)",
                file: file, line: line)
        }
        guard let fake = fake as? GitHubError else {
            return XCTFail(
                "fake did not throw a GitHubError: \(String(describing: fake)) — \(label)",
                file: file, line: line)
        }
        XCTAssertEqual(caseLabel(real), caseLabel(fake), label, file: file, line: line)
    }

    // MARK: - Identity

    func testConfigureURLMatchesTheRealClientForTheSameScope() {
        XCTAssertEqual(FakeGitHub().configureURL, makeReal().configureURL)
        XCTAssertEqual(FakeGitHub().configureURL, "https://github.com/acme/widgets")
    }

    // MARK: - Token failures

    func testTokenFailuresThrowTheSameGitHubErrorCasesAsTheRealClient() async {
        // 401 — the real client throws immediately, before any retry.
        StubProtocol.handler = { _ in (401, Data("bad credentials".utf8), [:]) }
        let real401 = await firstError { try await makeReal().fetchRegistrationToken() }
        let unauthorized = FakeGitHub()
        unauthorized.unauthorized = true
        let fake401 = await firstError { try await unauthorized.fetchRegistrationToken() }
        assertSameCase(real401, fake401, "401 must read as GitHubError.unauthorized on both sides")

        // 404 — also thrown immediately; the path differs per scope, but the
        // case is what callers branch on.
        StubProtocol.handler = { _ in (404, Data(#"{"message":"Not Found"}"#.utf8), [:]) }
        let real404 = await firstError { try await makeReal().fetchRegistrationToken() }
        let missing = FakeGitHub()
        missing.notFound = true
        let fake404 = await firstError { try await missing.fetchRegistrationToken() }
        assertSameCase(real404, fake404, "404 must read as GitHubError.notFound on both sides")

        // 403 — a plain 403 is a permissions error and is not retried; that is
        // exactly what `permissionDenied` simulates for the engine tests.
        StubProtocol.handler = { _ in (403, Data("nope".utf8), [:]) }
        let real403 = await firstError { try await makeReal().fetchRegistrationToken() }
        let forbidden = FakeGitHub()
        forbidden.permissionDenied = true
        let fake403 = await firstError { try await forbidden.fetchRegistrationToken() }
        assertSameCase(real403, fake403, "403 must read as GitHubError.forbidden on both sides")
    }

    // MARK: - Registration tokens

    func testRegistrationTokenCarriesARealisticTokenOnBothSides() async throws {
        StubProtocol.handler = { _ in
            (201, Data(#"{"token":"RT-real","expires_at":"2026-09-21T12:00:00Z"}"#.utf8), [:])
        }
        let real = try await makeReal().fetchRegistrationToken()
        let fake = try await FakeGitHub().fetchRegistrationToken()

        XCTAssertEqual(real.token, "RT-real", "the real client decodes the endpoint's token")
        XCTAssertFalse(fake.token.isEmpty, "the fake mints a token the registration script can use")
        XCTAssertGreaterThan(fake.expiresAt, Date(), "a freshly minted token is live, like the real one")
    }

    // MARK: - Queue reads

    func testQueuedJobsCarryAJobLabelSupersetLikeTheRealFilter() async throws {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/repos/acme/widgets/actions/runs" {
                return (200, Data(#"{"total_count":2,"workflow_runs":[{"id":101},{"id":102}]}"#.utf8), [:])
            }
            if path.hasSuffix("/jobs") {
                let runID = Int(request.url!.path.split(separator: "/").dropLast(1).last ?? "0") ?? 0
                // 101 carries every fleet label; 102 is missing "kinhin".
                let labels = runID == 101 ? #"["ubuntu-latest","macos","kinhin"]"# : #"["macos"]"#
                let body =
                    #"{"jobs":[{"id":1,"run_id":\#(runID),"name":"build","status":"queued","labels":\#(labels)}]}"#
                return (200, Data(body.utf8), [:])
            }
            XCTFail("unexpected path: \(path)")
            return (404, Data(), [:])
        }

        let requested: Set<String> = ["macos", "kinhin"]
        let realJobs = try await makeReal().queuedJobs(matching: requested)

        let fake = FakeGitHub()
        fake.queueDepth = 1
        fake.queueExtraLabels = ["ubuntu-latest"]
        let fakeJobs = try await fake.queuedJobs(matching: requested)

        XCTAssertEqual(realJobs.count, 1, "the real client keeps only jobs carrying every fleet label")
        XCTAssertEqual(fakeJobs.count, 1)
        XCTAssertEqual(
            Set(fakeJobs[0].labels), Set(realJobs[0].labels),
            "the fake reports the same label set the real API read would")
        XCTAssertTrue(
            requested.isSubset(of: Set(fakeJobs[0].labels)),
            "every fake job satisfies the superset filter the real client applies")
    }

    func testDeleteRunnerDropsOutOfTheNextListLikeTheRealCacheInvalidation() async throws {
        let deleted = Locked(false)
        StubProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
                deleted.withLock { $0 = true }
                return (204, Data(), [:])
            }
            if deleted.withLock({ $0 }) {
                return (200, Data(#"{"total_count":0,"runners":[]}"#.utf8), [:])
            }
            let body =
                #"{"total_count":1,"runners":[{"id":7,"name":"kinhin-1","status":"online","busy":false,"labels":[]}]}"#
            return (200, Data(body.utf8), [:])
        }

        let real = makeReal()
        let before = try await real.listRunners()
        XCTAssertEqual(before.map(\.id), [7])
        try await real.deleteRunner(id: 7)
        let after = try await real.listRunners()
        XCTAssertTrue(after.isEmpty, "the real client invalidates its runner cache on delete")

        let fake = FakeGitHub()
        fake.register(name: "kinhin-1")
        let fakeBefore = try await fake.listRunners()
        XCTAssertEqual(fakeBefore.map(\.id), [1])
        try await fake.deleteRunner(id: 1)
        let fakeAfter = try await fake.listRunners()
        XCTAssertTrue(fakeAfter.isEmpty, "the fake drops the runner from the next list too")
    }

    // MARK: - Cancel / skip

    func testCancelAndSkipReportAcceptedLikeTheRealClient() async throws {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/repos/acme/widgets/actions/runs" {
                let body = #"{"total_count":1,"workflow_runs":[{"id":1,"repository":{"full_name":"acme/widgets"}}]}"#
                return (200, Data(body.utf8), [:])
            }
            if path.hasSuffix("/cancel") || path.hasSuffix("/disable") {
                return (200, Data(), [:])
            }
            XCTFail("unexpected path: \(path)")
            return (404, Data(), [:])
        }

        let real = makeReal()
        let realCancelled = try await real.cancelWorkflowRun(ids: [1])
        let realSkipped = try await real.skipWorkflowRun(ids: [1])
        XCTAssertTrue(realCancelled, "a 2xx cancel reads as accepted")
        XCTAssertTrue(realSkipped, "a 2xx disable reads as accepted")

        let fake = FakeGitHub()
        let fakeCancelled = try await fake.cancelWorkflowRun(ids: [1])
        let fakeSkipped = try await fake.skipWorkflowRun(ids: [1])
        XCTAssertTrue(fakeCancelled, "the fake answers accepted, like the real 2xx")
        XCTAssertTrue(fakeSkipped, "the fake answers accepted, like the real 2xx")
    }

    // MARK: - Defaults

    func testRateLimitIsUnknownByDefaultLikeTheProtocol() {
        XCTAssertNil(makeReal().rateLimit, "no response seen yet: unknown")
        XCTAssertNil(FakeGitHub().rateLimit, "the fake reports unknown like every other forge")
    }

    func testProjectFileFollowsTheRealReadContract() async throws {
        // Absent file: the real client turns 404 into nil, not an error.
        StubProtocol.handler = { _ in (404, Data(#"{"message":"Not Found"}"#.utf8), [:]) }
        let realMissing = try await makeReal().projectFile(repository: "acme/api", ref: "main")
        XCTAssertNil(realMissing, "404 means the repository has no .kinhin.yml, not a failure")

        let fake = FakeGitHub()
        let fakeMissing = try await fake.projectFile(repository: "acme/api", ref: "main")
        XCTAssertNil(fakeMissing, "same nil contract for a file the fake was never given")

        // Present file: both answer with the file's bytes.
        let body = Data("toolchains:\n  specs: [go@1.22.5]\n".utf8)
        StubProtocol.handler = { [body] _ in (200, body, [:]) }
        let realFile = try await makeReal().projectFile(repository: "acme/api", ref: "main")
        fake.projectFiles = ["acme/api@main": body]
        let fakeFile = try await fake.projectFile(repository: "acme/api", ref: "main")

        XCTAssertEqual(realFile, body)
        XCTAssertEqual(fakeFile, realFile)
        let calls = fake.projectFileCalls
        XCTAssertEqual(
            calls, ["acme/api@main", "acme/api@main"],
            "the fake records each read under the same key the engine's cache uses (repo@ref)")
    }
}
