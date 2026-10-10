import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Contract for `FakeGitea` as a `Forge`: for the cases the engine tests
/// rely on it must answer like the real `GiteaForge` over `GiteaClient` —
/// the same identity and behavior (one long-lived registration token, the
/// idle-grace exit, per-repo attribution derived from the scope), the same
/// registration URL, task-queue reads that carry repo attribution, an idle
/// instance reading empty on every surface, runner ids validated the same
/// way, and the shared `.kinhin.yml` read contract (404 → nil, `repo@ref`
/// call keys). The real side is a `GiteaForge` over `StubProtocol`; no
/// network is involved.
final class FakeGiteaContractTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    /// The real forge built with the credentials the fake carries. The
    /// registration token is the one the fake mints, and the demand floor
    /// stays 0 (its default) so an empty queue stays empty on both sides.
    private func makeReal(labels: [String] = ["kinhin"]) -> GiteaForge {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = GiteaClient(
            credentials: GiteaCredentials(token: "t", scope: "acme/api", instance: "https://gitea.example.com"),
            session: URLSession(configuration: config))
        return GiteaForge(
            credentials: .gitea(token: "t", scope: "acme/api", instance: "https://gitea.example.com"),
            labels: labels, client: client, registrationToken: "gt")
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

    // MARK: - Identity

    func testIdentityAndBehaviorMatchTheRealForgeBuiltWithTheSameCredentials() {
        let real = makeReal()
        let fake = FakeGitea()

        XCTAssertEqual(fake.id, real.id)
        XCTAssertEqual(fake.name, real.name, "both label themselves after the forge id")
        XCTAssertEqual(fake.account, real.account, "the key the engine's forge map is built from")
        XCTAssertEqual(fake.credentials, real.credentials, "same token, scope and instance")
        XCTAssertEqual(fake.labels, real.labels, "the fleet's labels the fake queues demand for")
        XCTAssertEqual(fake.registration, real.registration, "one long-lived token, captured up front")
        XCTAssertEqual(fake.exitSemantics, real.exitSemantics, "runner daemons stay: busy, then a grace period")
        XCTAssertEqual(
            fake.attributesByRepo, real.attributesByRepo,
            "a single-repository scope has no per-repo breakdown to show")
        XCTAssertNil(fake.rateLimit, "neither side reports an API budget")
    }

    func testRegistrationURLMatchesTheRealForge() {
        XCTAssertEqual(FakeGitea().registrationURL(), makeReal().registrationURL())
        XCTAssertEqual(
            FakeGitea().registrationURL(), "https://gitea.example.com",
            "the in-VM bootstrap registers against the instance itself")
    }

    // MARK: - Registration tokens

    func testRegistrationTokensShareTheCapturedTokenLikeTheRealForge() async throws {
        let names = ["kinhin-1", "kinhin-2"]
        let real = makeReal()
        let fake = FakeGitea()

        let realMinted = try await real.mintRegistrationToken()
        let fakeMinted = try await fake.mintRegistrationToken()
        XCTAssertEqual(fakeMinted, realMinted, "both hand out the token captured at construction")

        let realTokens = try await real.registrationTokens(runnerNames: names, labels: ["macos"])
        let fakeTokens = try await fake.registrationTokens(runnerNames: names, labels: ["macos"])
        XCTAssertEqual(Set(fakeTokens.keys), Set(names), "every name gets a token")
        XCTAssertEqual(Set(realTokens.keys), Set(names))
        XCTAssertEqual(
            Set(fakeTokens.values), Set(realTokens.values),
            "one shared token registers every runner on both sides")
    }

    // MARK: - Queue reads

    func testQueuedJobsCarryRepoAttributionLikeTheRealTaskQueue() async throws {
        StubProtocol.handler = { request in
            // An older server (this stub) has no `/actions/jobs`; the client asks it first and falls back to tasks.
            if request.url!.path.hasSuffix("/actions/jobs") { return (404, Data("{}".utf8), [:]) }
            XCTAssertTrue(request.url!.path.hasSuffix("/api/v1/repos/acme/api/actions/tasks"), request.url!.path)
            XCTAssertTrue(request.url!.query?.contains("status=waiting") == true, "queued demand is the waiting list")
            let body = """
                {"total_count":2,"entries":[
                  {"id":11,"name":"build","repo_full_name":"acme/api","head_branch":"main","head_sha":"abc123"},
                  {"id":12,"title":"Nightly","repository":{"full_name":"acme/web"}}
                ]}
                """
            return (200, Data(body.utf8), [:])
        }
        let realJobs = try await makeReal().queuedJobs()

        let fake = FakeGitea()
        fake.queueDepth = 2
        fake.queueRefs = ["main"]
        fake.queueShas = ["abc123"]
        let fakeJobs = try await fake.queuedJobs()

        XCTAssertEqual(realJobs.count, 2)
        XCTAssertEqual(fakeJobs.count, 2, "queueDepth is the fake's demand, like the task queue's count")
        XCTAssertEqual(
            realJobs.map(\.repository), ["acme/api", "acme/web"], "each task is attributed to its repo")
        XCTAssertEqual(
            fakeJobs.map(\.repository), ["acme/api", "acme/api"], "the fake attributes to its own scope")
        XCTAssertEqual(fakeJobs.first?.ref, realJobs.first?.ref, "branch attribution passes through on both sides")
        XCTAssertEqual(fakeJobs.first?.sha, realJobs.first?.sha, "commit attribution passes through on both sides")
        XCTAssertTrue(
            realJobs.allSatisfy { $0.runnerName == nil }, "queued work has no runner yet")
        XCTAssertTrue(
            fakeJobs.allSatisfy { $0.runnerName == nil }, "neither side pretends a queued job is running")
        XCTAssertNil(realJobs.first?.labels, "Gitea has no label filtering, so its queue carries no labels")
        XCTAssertNil(fakeJobs.first?.labels, "the fake mirrors that: demand counts, it never filters")
        XCTAssertTrue(
            realJobs.allSatisfy { !$0.isFork } && fakeJobs.allSatisfy { !$0.isFork },
            "task-queue entries are never fork pull requests")
    }

    func testAnIdleInstanceReadsEmptyOnEverySurfaceOnBothSides() async throws {
        StubProtocol.handler = { request in
            let url = request.url!
            if url.query?.contains("status=") == true {
                return (200, Data(#"{"total_count":0,"entries":[]}"#.utf8), [:])
            }
            if url.path.hasSuffix("/actions/runners") {
                return (200, Data(#"{"total_count":0,"runners":[]}"#.utf8), [:])
            }
            XCTFail("unexpected path: \(url.path)")
            return (404, Data(), [:])
        }
        let real = makeReal()

        let realQueued = try await real.queuedJobs()
        let fakeQueued = try await FakeGitea().queuedJobs()
        XCTAssertEqual(realQueued, [], "an empty task queue is no demand")
        XCTAssertEqual(fakeQueued, [], "the fake starts at depth 0")

        let realRunning = try await real.runningJobs()
        let fakeRunning = try await FakeGitea().runningJobs()
        XCTAssertEqual(realRunning, [], "nothing is running on a fresh instance")
        XCTAssertEqual(fakeRunning, [])

        let realRunners = try await real.runners()
        let fakeRunners = try await FakeGitea().runners()
        XCTAssertEqual(realRunners, [], "no runners registered yet")
        XCTAssertEqual(fakeRunners, [])
    }

    // MARK: - Runner deletion

    func testDeletingAListedRunnerIdSucceedsOnBothSides() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertTrue(request.url!.path.hasSuffix("/actions/runners/7"), request.url!.path)
            return (204, Data(), [:])
        }
        try await makeReal().deleteRunner(id: "7")
        try await FakeGitea().deleteRunner(id: "7")
    }

    func testAMalformedRunnerIDFailsTheSameWayOnBothSides() async {
        let realError = await firstError { try await makeReal().deleteRunner(id: "not-a-number") }
        let fakeError = await firstError { try await FakeGitea().deleteRunner(id: "not-a-number") }

        XCTAssertEqual(
            realError as? EngineError, EngineError.invalidRunnerID(forge: .gitea, id: "not-a-number"),
            "the real forge validates the id before any request")
        XCTAssertEqual(
            fakeError as? EngineError, EngineError.invalidRunnerID(forge: .gitea, id: "not-a-number"),
            "the fake must fail identically instead of silently succeeding")
    }

    // MARK: - Defaults

    func testRateLimitIsUnknownByDefaultLikeTheProtocol() {
        XCTAssertNil(makeReal().rateLimit, "no response seen yet: unknown")
        XCTAssertNil(FakeGitea().rateLimit, "the fake reports unknown like every other forge")
    }

    // MARK: - Project file

    func testProjectFileFollowsTheRealReadContract() async throws {
        // Absent file: the real client turns 404 into nil, not an error.
        StubProtocol.handler = { _ in (404, Data(#"{"message":"Not Found"}"#.utf8), [:]) }
        let realMissing = try await makeReal().projectFile(repository: "acme/api", ref: "main")
        XCTAssertNil(realMissing, "404 means the repository has no .kinhin.yml, not a failure")

        let fake = FakeGitea()
        let fakeMissing = try await fake.projectFile(repository: "acme/api", ref: "main")
        XCTAssertNil(fakeMissing, "same nil contract for a file the fake was never given")

        // Present file: both answer with the file's bytes.
        let body = Data("toolchains:\n  specs: [go@1.22.5]\n".utf8)
        StubProtocol.handler = { [body] request in
            let file = ProjectFileLoader.fileName
            XCTAssertTrue(
                request.url!.absoluteString.hasSuffix("/api/v1/repos/acme/api/raw/\(file)?ref=main"),
                request.url!.absoluteString)
            return (200, body, [:])
        }
        let realFile = try await makeReal().projectFile(repository: "acme/api", ref: "main")
        fake.projectFiles = ["acme/api@main": body]
        let fakeFile = try await fake.projectFile(repository: "acme/api", ref: "main")

        XCTAssertEqual(realFile, body)
        XCTAssertEqual(fakeFile, realFile)
        XCTAssertEqual(
            fake.projectFileCalls, ["acme/api@main", "acme/api@main"],
            "the fake records each read under the same key the engine's cache uses (repo@ref)")
    }
}
