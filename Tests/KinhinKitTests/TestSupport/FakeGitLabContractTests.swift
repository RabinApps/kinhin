import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Contract for `FakeGitLab` as a `Forge`: for the cases the engine tests
/// rely on it must answer like the real `GitLabForge` over `GitLabClient` —
/// the same identity and behavior (registration created per runner, exit by
/// deregistration, per-repo attribution from the resolved scope), the same
/// registration URL, per-runner registration tokens keyed by name, queued
/// jobs that already passed the account-label filter and carry the
/// project's repo, an idle instance reading empty on every surface, runner
/// ids validated the same way, and the shared `.kinhin.yml` read contract
/// (404 → nil, `repo@ref` call keys). The real side is a `GitLabForge`
/// over `StubProtocol`; no network is involved.
final class FakeGitLabContractTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    /// The real forge built with the credentials the fake carries, resolved
    /// to the project scope the fake's hardwired scope names.
    private func makeReal(
        labels: [String] = ["kinhin"], instance: String = "https://gitlab.example.com"
    ) -> GitLabForge {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = GitLabClient(
            credentials: GitLabCredentials(token: "t", scope: "acme/api", instance: instance),
            session: URLSession(configuration: config))
        return GitLabForge(
            credentials: .gitlab(token: "t", scope: "acme/api", instance: instance),
            labels: labels, client: client, scope: .project(id: 7, path: "acme/api"), runnerListTTL: 0)
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
        let fake = FakeGitLab()

        XCTAssertEqual(fake.id, real.id)
        XCTAssertEqual(fake.name, real.name, "both label themselves after the forge id")
        XCTAssertEqual(fake.account, real.account, "the key the engine's forge map is built from")
        XCTAssertEqual(fake.credentials, real.credentials, "same token, scope and instance")
        XCTAssertEqual(fake.labels, real.labels, "the labels queued jobs must carry to be this fleet's")
        XCTAssertEqual(fake.registration, real.registration, "one runner created per name, each with its own token")
        XCTAssertEqual(fake.exitSemantics, real.exitSemantics, "the runner deregisters itself after its job")
        XCTAssertEqual(
            fake.attributesByRepo, real.attributesByRepo,
            "a project scope has no per-repo breakdown to show")
        XCTAssertNil(fake.rateLimit, "neither side reports an API budget")
    }

    func testRegistrationURLMatchesTheRealForgeEvenWithATrailingSlash() {
        XCTAssertEqual(FakeGitLab().registrationURL(), makeReal().registrationURL())
        XCTAssertEqual(
            FakeGitLab().registrationURL(), makeReal(instance: "https://gitlab.example.com/").registrationURL(),
            "the real forge strips the trailing slash; the bootstrap gets one URL either way")
        XCTAssertEqual(FakeGitLab().registrationURL(), "https://gitlab.example.com")
    }

    // MARK: - Registration

    func testThereIsNoSharedRegistrationTokenOnEitherSide() async {
        let realError = await firstError { try await makeReal().mintRegistrationToken() }
        let fakeError = await firstError { try await FakeGitLab().mintRegistrationToken() }

        guard let real = realError as? EngineError, case .registrationFailed(let realVM, _) = real else {
            return XCTFail("the real forge must refuse a shared token: \(String(describing: realError))")
        }
        guard let fake = fakeError as? EngineError, case .registrationFailed(let fakeVM, _) = fake else {
            return XCTFail("the fake must refuse the same way: \(String(describing: fakeError))")
        }
        XCTAssertEqual(fakeVM, realVM, "the error names the account the engine keys on")
        XCTAssertEqual(fakeVM, "gitlab")
    }

    func testRegistrationTokensKeyEveryNameLikeTheRealRunnerCreation() async throws {
        // The real forge creates one runner per name and returns the token
        // the API answers with, so tokens are distinct per name.
        let counter = Mutex(0)
        StubProtocol.handler = { _ in
            let nth = counter.withLock { value -> Int in
                defer { value += 1 }
                return value
            }
            return (201, Data(#"{"id":99,"token":"glrt-\#(nth)"}"#.utf8), [:])
        }
        let names = ["kinhin-1", "kinhin-2"]

        let realTokens = try await makeReal().registrationTokens(runnerNames: names, labels: ["macos"])
        let fakeTokens = try await FakeGitLab().registrationTokens(runnerNames: names, labels: ["macos"])

        XCTAssertEqual(Set(realTokens.keys), Set(names), "every name gets a runner")
        XCTAssertEqual(Set(fakeTokens.keys), Set(names))
        XCTAssertEqual(
            Set(realTokens.values).count, names.count, "each runner authenticates with its own token")
        XCTAssertEqual(
            Set(fakeTokens.values).count, names.count, "the fake mints one distinct token per name too")
    }

    // MARK: - Queue reads

    func testQueuedJobsAreTheFleetsOwnAndCarryTheProjectsRepo() async throws {
        StubProtocol.handler = { request in
            XCTAssertTrue(
                request.url!.path.hasSuffix("/api/v4/projects/7/jobs"),
                "a project scope reads its own jobs directly: \(request.url!.path)")
            XCTAssertTrue(
                request.url!.query?.contains("scope%5B%5D=pending") == true
                    || request.url!.query?.contains("scope[]=pending") == true,
                "queued demand is the pending list")
            let body = """
                [{"id":1,"name":"build","tag_list":["kinhin"],"ref":"main","commit":{"id":"abc123"}},
                 {"id":2,"name":"linux","tag_list":["docker"]},
                 {"id":3,"name":"untagged","tag_list":[]}]
                """
            return (200, Data(body.utf8), [:])
        }
        let realJobs = try await makeReal().queuedJobs()

        let fake = FakeGitLab()
        fake.queueDepth = 1
        fake.queueRefs = ["main"]
        fake.queueShas = ["abc123"]
        let fakeJobs = try await fake.queuedJobs()

        XCTAssertEqual(
            realJobs.map(\.name), ["build"],
            "jobs without every account label are not this fleet's demand")
        XCTAssertEqual(
            fakeJobs.count, 1, "the fake's depth is demand that already passed that filter")
        XCTAssertEqual(
            fakeJobs.first?.repository, realJobs.first?.repository,
            "both attribute the job to the scope's project")
        XCTAssertEqual(fakeJobs.first?.ref, realJobs.first?.ref, "branch attribution passes through")
        XCTAssertEqual(fakeJobs.first?.sha, realJobs.first?.sha, "commit attribution passes through")
        XCTAssertEqual(
            fakeJobs.first?.labels, realJobs.first?.labels,
            "both report the labels that route a job to a pool — a superset of the account's")
        XCTAssertNil(fakeJobs.first?.runnerName, "queued work has no runner yet")
        XCTAssertEqual(fakeJobs.first?.isFork, realJobs.first?.isFork, "queued jobs are never fork PRs")
    }

    func testAnIdleInstanceReadsEmptyOnEverySurfaceOnBothSides() async throws {
        StubProtocol.handler = { _ in (200, Data("[]".utf8), [:]) }
        let real = makeReal()

        let realQueued = try await real.queuedJobs()
        let fakeQueued = try await FakeGitLab().queuedJobs()
        XCTAssertEqual(realQueued, [], "no pending jobs is no demand")
        XCTAssertEqual(fakeQueued, [], "the fake starts at depth 0")

        let realRunning = try await real.runningJobs()
        let fakeRunning = try await FakeGitLab().runningJobs()
        XCTAssertEqual(realRunning, [], "nothing is running on a fresh scope")
        XCTAssertEqual(fakeRunning, [])

        let realRunners = try await real.runners()
        let fakeRunners = try await FakeGitLab().runners()
        XCTAssertEqual(realRunners, [], "no runners created yet")
        XCTAssertEqual(fakeRunners, [])
    }

    // MARK: - Runner deletion

    func testDeletingAListedRunnerIdSucceedsOnBothSides() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertTrue(request.url!.path.hasSuffix("/api/v4/runners/7"), request.url!.path)
            return (204, Data(), [:])
        }
        try await makeReal().deleteRunner(id: "7")
        try await FakeGitLab().deleteRunner(id: "7")
    }

    func testAMalformedRunnerIDFailsTheSameWayOnBothSides() async {
        let realError = await firstError { try await makeReal().deleteRunner(id: "not-a-number") }
        let fakeError = await firstError { try await FakeGitLab().deleteRunner(id: "not-a-number") }

        XCTAssertEqual(
            realError as? EngineError, EngineError.invalidRunnerID(forge: .gitlab, id: "not-a-number"),
            "the real forge validates the id before any request")
        XCTAssertEqual(
            fakeError as? EngineError, EngineError.invalidRunnerID(forge: .gitlab, id: "not-a-number"),
            "the fake must fail identically instead of silently succeeding")
    }

    // MARK: - Project file

    func testProjectFileFollowsTheRealReadContract() async throws {
        // Absent file: the real client turns 404 into nil, not an error.
        StubProtocol.handler = { _ in (404, Data("Not Found".utf8), [:]) }
        let realMissing = try await makeReal().projectFile(repository: "acme/api", ref: "main")
        XCTAssertNil(realMissing, "404 means the repository has no .kinhin.yml, not a failure")

        let fake = FakeGitLab()
        let fakeMissing = try await fake.projectFile(repository: "acme/api", ref: "main")
        XCTAssertNil(fakeMissing, "same nil contract for a file the fake was never given")

        // Present file: both answer with the file's bytes.
        let body = Data("toolchains:\n  specs: [go@1.22.5]\n".utf8)
        StubProtocol.handler = { [body] request in
            XCTAssertTrue(
                request.url!.absoluteString.contains(
                    "/api/v4/projects/acme%2Fapi/repository/files/\(ProjectFileLoader.fileName)/raw?ref=main"),
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
