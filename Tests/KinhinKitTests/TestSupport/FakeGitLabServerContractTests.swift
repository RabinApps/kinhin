import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Contract for `FakeGitLabServer` as a stand-in for the GitLab API: driven
/// through the real `GitLabForge`/`GitLabClient` over `StubProtocol`, its
/// responses must read exactly like the canonical API responses the shared
/// `FakeGitLab` is pinned to (`FakeGitLabContractTests`) — the same per-name
/// registration tokens with the posted `tag_list`, the same account-label
/// filter on queued demand, the same busy/online runner read, the same empty
/// answers on an idle project, and the same delete contract (204 for a
/// listed id, 404 for an unknown one, malformed ids rejected before any
/// request). The real side is a `GitLabForge` over canned canonical JSON;
/// no network is involved.
final class FakeGitLabServerContractTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func makeClient() -> GitLabClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return GitLabClient(
            credentials: GitLabCredentials(token: "glpat", scope: "acme/api"),
            session: URLSession(configuration: config))
    }

    /// The real forge talking to the simulated server — the double under test.
    private func makeForge(
        server: FakeGitLabServer, labels: [String] = ["macos"]
    ) -> GitLabForge {
        StubProtocol.handler = { server.handle($0) }
        return GitLabForge(
            credentials: .gitlab(token: "glpat", scope: "acme/api", instance: GitLabCredentials.defaultInstance),
            labels: labels, client: makeClient(), scope: .project(id: 7, path: "acme/api"), runnerListTTL: 0)
    }

    /// The real forge over canned canonical responses — the reference shape
    /// `FakeGitLabContractTests` pins the shared fake against.
    private func makeForge(
        canned: @escaping StubHandler, labels: [String] = ["macos"]
    ) -> GitLabForge {
        StubProtocol.handler = canned
        return GitLabForge(
            credentials: .gitlab(token: "glpat", scope: "acme/api", instance: GitLabCredentials.defaultInstance),
            labels: labels, client: makeClient(), scope: .project(id: 7, path: "acme/api"), runnerListTTL: 0)
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

    // MARK: - Registration

    func testRegistrationMintsTheSamePerNameTokensAsTheSharedFake() async throws {
        let server = FakeGitLabServer()
        let names = ["kinhin-1", "kinhin-2"]
        let labels = ["macos", "kinhin-host"]

        let serverTokens = try await makeForge(server: server).registrationTokens(runnerNames: names, labels: labels)
        let fakeTokens = try await FakeGitLab().registrationTokens(runnerNames: names, labels: labels)

        XCTAssertEqual(Set(serverTokens.keys), Set(names), "every name gets a runner")
        XCTAssertEqual(
            serverTokens, fakeTokens,
            "both fakes mint the same per-name token the real API answers with")
        XCTAssertEqual(
            Set(serverTokens.values).count, names.count,
            "each runner authenticates with its own token")
        XCTAssertEqual(
            server.createdTags, [labels, labels],
            "the real client posts tag_list per created runner; the server parses it back")
    }

    // MARK: - Queue reads

    func testQueuedJobsPassTheAccountLabelFilterLikeTheCanonicalResponse() async throws {
        // Canonical: the real API's pending list — one matching job, one with
        // a foreign label, one untagged (the shape FakeGitLabContractTests
        // pins: only jobs carrying every account label are demand).
        let canonicalBody = """
            [{"id":1,"name":"build","tag_list":["macos"],"ref":"main","commit":{"id":"abc123"}},
             {"id":2,"name":"linux","tag_list":["docker"]},
             {"id":3,"name":"untagged","tag_list":[]}]
            """
        let canonical = makeForge(canned: { _ in (200, Data(canonicalBody.utf8), [:]) })
        let canonicalJobs = try await canonical.queuedJobs()

        let server = FakeGitLabServer()
        server.pending = [(1, "build", ["macos"]), (2, "linux", ["docker"]), (3, "untagged", [])]
        let serverJobs = try await makeForge(server: server).queuedJobs()

        XCTAssertEqual(canonicalJobs.map(\.name), ["build"], "only the fully-labelled job is demand")
        XCTAssertEqual(
            serverJobs.map(\.name), canonicalJobs.map(\.name),
            "the server's rows pass the same filter as the canonical response")
        XCTAssertEqual(serverJobs.map(\.labels), canonicalJobs.map(\.labels))
        XCTAssertEqual(serverJobs.map(\.repository), canonicalJobs.map(\.repository))
        XCTAssertNil(serverJobs.first?.ref, "the simulated rows carry no ref — that is all the real client sees")
        XCTAssertNotNil(canonicalJobs.first?.ref, "the canonical ones do, so both legs exercise the same parser")

        // The shared fake's depth is demand that already passed this filter.
        let fake = FakeGitLab()
        fake.queueDepth = 1
        let fakeJobs = try await fake.queuedJobs()
        XCTAssertEqual(
            fakeJobs.map(\.labels), [fake.labels],
            "the fake's depth is demand that already passed this filter: every job carries the account labels")
        XCTAssertEqual(fakeJobs.map(\.repository), [canonicalJobs[0].repository])
    }

    func testAnIdleProjectReadsEmptyOnEverySurfaceLikeTheSharedFake() async throws {
        let server = FakeGitLabServer()
        let forge = makeForge(server: server)

        let serverQueued = try await forge.queuedJobs()
        let serverRunning = try await forge.runningJobs()
        let serverRunners = try await forge.runners()
        XCTAssertEqual(serverQueued, [], "no pending jobs is no demand")
        XCTAssertEqual(serverRunning, [])
        XCTAssertEqual(serverRunners, [], "no runners created yet")

        let fake = FakeGitLab()
        let fakeQueued = try await fake.queuedJobs()
        let fakeRunning = try await fake.runningJobs()
        let fakeRunners = try await fake.runners()
        XCTAssertEqual(fakeQueued, [])
        XCTAssertEqual(fakeRunning, [])
        XCTAssertEqual(fakeRunners, [])
    }

    // MARK: - Runners and running jobs

    func testARunningJobAndItsRunnerReadBusyAndOnlineLikeTheCanonicalResponse() async throws {
        // Server leg: a created runner that came online and took a job.
        let server = FakeGitLabServer()
        let forge = makeForge(server: server)
        _ = try await forge.registrationTokens(runnerNames: ["kinhin-1"], labels: [])
        server.setStatus("kinhin-1", "online")
        server.running = [(9, "test", ["macos"], "kinhin-1")]
        let serverRunning = try await forge.runningJobs()
        let serverRunners = try await forge.runners()

        // Canonical leg: the same facts as canned real-API JSON.
        let runnersBody = #"[{"id":1,"description":"kinhin-1","status":"online"}]"#
        let jobsBody = #"[{"id":9,"name":"test","tag_list":["macos"],"runner":{"description":"kinhin-1"}}]"#
        let canonical = makeForge(canned: { request in
            if request.url!.path.hasSuffix("/jobs") { return (200, Data(jobsBody.utf8), [:]) }
            return (200, Data(runnersBody.utf8), [:])
        })
        let canonicalRunning = try await canonical.runningJobs()
        let canonicalRunners = try await canonical.runners()

        XCTAssertEqual(serverRunning.map(\.name), canonicalRunning.map(\.name))
        XCTAssertEqual(
            serverRunning.map(\.runnerName), ["kinhin-1"],
            "the runner description on a running job is what attributes the job")
        XCTAssertEqual(
            serverRunners, canonicalRunners,
            "the server's runner rows parse to the same ForgeRunner the canonical ones do")
        XCTAssertEqual(serverRunners.first?.online, true, "a runner that answered status=online is online")
        XCTAssertEqual(serverRunners.first?.busy, true, "a runner with a running job is busy on both legs")
    }

    func testDeletingRunnersFollowsTheRealDeleteContract() async throws {
        let server = FakeGitLabServer()
        let forge = makeForge(server: server)
        _ = try await forge.registrationTokens(runnerNames: ["kinhin-1"], labels: [])
        let created = try await forge.runners()
        let id = try XCTUnwrap(created.first?.id)

        try await forge.deleteRunner(id: id)
        let afterDelete = try await forge.runners()
        XCTAssertEqual(
            afterDelete, [],
            "the server removed the listed runner; the client re-reads (TTL 0)")

        // Unknown id: the real API answers 404 and the client throws — the
        // server must fail the same way instead of silently succeeding.
        let serverError = await firstError { try await makeForge(server: server).deleteRunner(id: "999") }
        let canonicalError = await firstError {
            try await makeForge(canned: { _ in (404, Data("404 Not Found".utf8), [:]) })
                .deleteRunner(id: "999")
        }
        XCTAssertNotNil(serverError, "deleting a runner the server never had must fail")
        XCTAssertNotNil(canonicalError, "the canonical 404 fails too")
        XCTAssertEqual(
            "\(serverError!)", "\(canonicalError!)",
            "the simulated 404 reads exactly like the canonical one")
    }

    // MARK: - Validation

    func testAMalformedRunnerIDFailsIdenticallyToTheSharedFake() async {
        let serverError = await firstError {
            try await makeForge(server: FakeGitLabServer()).deleteRunner(id: "not-a-number")
        }
        let fakeError = await firstError { try await FakeGitLab().deleteRunner(id: "not-a-number") }

        XCTAssertEqual(
            serverError as? EngineError, EngineError.invalidRunnerID(forge: .gitlab, id: "not-a-number"),
            "the real forge validates the id before any request reaches the server")
        XCTAssertEqual(
            fakeError as? EngineError, EngineError.invalidRunnerID(forge: .gitlab, id: "not-a-number"),
            "the shared fake must fail identically")
    }
}
