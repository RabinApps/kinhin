import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Each forge's step/job output lookup behind `StubProtocol`: the requests it
/// makes, and the cleaned (and, for GitHub, step-sliced) text it returns.
final class PipelineLogFetchTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - GitHub

    func testGitHubFollowsTheSignedRedirectWithoutCredentialsAndSlicesTheStep() async throws {
        let seen = Locked<[(String, String?)]>([])
        StubProtocol.handler = { request in
            seen.withLock {
                $0.append((request.url?.absoluteString ?? "", request.value(forHTTPHeaderField: "Authorization")))
            }
            if request.url?.path == "/repos/acme/widgets/actions/jobs/11/logs" {
                return (302, Data(), ["Location": "https://blob.example.com/logs/abc?sig=1"])
            }
            let log = """
                2026-10-02T10:00:01.1000000Z checkout output
                2026-10-02T10:00:06.0000000Z test output
                """
            return (200, Data(log.utf8), [:])
        }
        let client = GitHubClient(
            credentials: GitHubCredentials(token: "secret", scope: "acme/widgets"), session: session())
        let forge = GitHubForge(
            credentials: .github(token: "secret", scope: "acme/widgets"), labels: [], client: client)
        let steps = [
            PipelineStep(name: "Checkout", state: .succeeded, startedAt: PipelineParsing.date("2026-10-02T10:00:01Z")),
            PipelineStep(name: "Test", state: .running, startedAt: PipelineParsing.date("2026-10-02T10:00:05Z")),
        ]
        let job = PipelineJob(id: "11", name: "build", state: .running, steps: steps, logRef: "acme/widgets|11")

        let step = try await forge.pipelineLog(job: job, step: steps[1])
        XCTAssertEqual(step?.text, "2026-10-02T10:00:06.0000000Z test output")
        XCTAssertEqual(step?.scope, .step)
        let whole = try await forge.pipelineLog(job: job, step: nil)
        XCTAssertEqual(whole?.scope, .job)
        XCTAssertTrue(whole?.text.contains("checkout output") == true)

        let requests = seen.withLock { $0 }
        let signed = requests.first { $0.0.hasPrefix("https://blob.example.com") }
        XCTAssertNotNil(signed)
        XCTAssertNil(signed?.1, "the token must not ride to the signed URL")
    }

    func testGitHubLogNotAvailableYetIsNil() async throws {
        StubProtocol.handler = { _ in (404, Data(), [:]) }
        let client = GitHubClient(credentials: GitHubCredentials(token: "t", scope: "acme/widgets"), session: session())
        let raw = try await client.jobLog(repository: "acme/widgets", jobID: 1)
        XCTAssertNil(raw)
    }

    func testGitHubLogRedirectFollowReturnsNilWhenTheSignedBlobIsNotFound() async throws {
        // A live job's log blob is not written yet; the signed URL answers 404
        // and the client returns nil rather than surfacing a hard error.
        let redirected = Locked(false)
        StubProtocol.handler = { request in
            if request.url?.path == "/repos/acme/widgets/actions/jobs/11/logs" {
                redirected.withLock { $0 = true }
                return (302, Data(), ["Location": "https://blob.example.com/logs/missing?sig=1"])
            }
            guard request.url?.host == "blob.example.com" else {
                return (200, Data(), [:])  // not our scenario
            }
            return (404, Data(), ["x-blob-error": "BlobNotFound"])
        }
        let client = GitHubClient(
            credentials: GitHubCredentials(token: "t", scope: "acme/widgets"), session: session())
        let raw = try await client.jobLog(repository: "acme/widgets", jobID: 11)
        XCTAssertNil(raw)
        XCTAssertTrue(redirected.withLock { $0 })
    }

    func testGitHubJobLogFollowsTheInstanceBlobRedirectWithoutCredentials() async throws {
        // GHES answers the log endpoint with a redirect to its own blob
        // storage on another host; the signed URL must be followed, without
        // the token riding along.
        let seen = Locked<[(String, String?)]>([])
        StubProtocol.handler = { request in
            seen.withLock {
                $0.append((request.url?.absoluteString ?? "", request.value(forHTTPHeaderField: "Authorization")))
            }
            if request.url?.host == "github.example.com" {
                return (302, Data(), ["Location": "https://blob.example.invalid/logs/abc?sig=1"])
            }
            return (200, Data("enterprise log line\n".utf8), [:])
        }
        let client = GitHubClient(
            credentials: GitHubCredentials(
                token: "secret", scope: "acme/widgets", instance: "https://github.example.com"),
            session: session())

        let raw = try await client.jobLog(repository: "acme/widgets", jobID: 7)

        XCTAssertEqual(raw, "enterprise log line\n")
        let signed = seen.withLock { $0.first { $0.0.contains("blob.example.invalid") } }
        XCTAssertNotNil(signed, "the instance's blob redirect must be followed")
        XCTAssertNil(signed?.1, "the token must not ride to the signed URL")
    }

    func testGitHubRejectsAMalformedRepositoryRef() async {
        let client = GitHubClient(credentials: GitHubCredentials(token: "t", scope: "acme/widgets"), session: session())
        do {
            _ = try await client.jobLog(repository: "../etc", jobID: 1)
            XCTFail("expected an error")
        } catch {}
    }

    // MARK: - GitLab

    func testGitLabTraceIsCleanedAndJobScoped() async throws {
        let path = Locked("")
        StubProtocol.handler = { request in
            path.withLock { $0 = request.url?.path ?? "" }
            return (200, Data("section_start:1:build\r\u{1B}[0K\u{1B}[32mcompiling\u{1B}[0m\n".utf8), [:])
        }
        let client = GitLabClient(
            credentials: GitLabCredentials(token: "glpat", scope: "acme/api"), session: session())
        let forge = GitLabForge(
            credentials: .gitlab(token: "glpat", scope: "acme/api", instance: GitLabCredentials.defaultInstance),
            labels: ["macos"], client: client, scope: .project(id: 7, path: "acme/api"), runnerListTTL: 0)
        let job = PipelineJob(id: "2", name: "test", state: .running, logRef: "7|2")
        let log = try await forge.pipelineLog(job: job, step: nil)
        XCTAssertEqual(log?.text, "compiling\n")
        XCTAssertEqual(log?.scope, .job)
        XCTAssertTrue(path.withLock { $0 }.hasSuffix("/projects/7/jobs/2/trace"))
    }

    // MARK: - Buildkite

    func testBuildkiteReadsTheJobLogContent() async throws {
        let path = Locked("")
        StubProtocol.handler = { request in
            path.withLock { $0 = request.url?.path ?? "" }
            return (200, Data(#"{"content":"\u001b_bk;t=1\u0007~~~ Running tests\nok\n"}"#.utf8), [:])
        }
        let forge = BuildkiteForge(
            credentials: ForgeCredentials(forge: .buildkite, token: "bkua", scope: "acme/Mac Fleet"),
            labels: ["queue=kinhin"],
            client: BuildkiteClient(
                credentials: BuildkiteCredentials(token: "bkua", scope: "acme/Mac Fleet"), session: session()),
            cluster: BuildkiteCluster(id: "c-1", name: "Mac Fleet"), agentToken: "bkct", account: "ci", listTTL: 0)
        let job = PipelineJob(id: "j2", name: "Test", state: .running, logRef: "ios|88|j2")
        let log = try await forge.pipelineLog(job: job, step: nil)
        XCTAssertEqual(log?.text, "~~~ Running tests\nok\n")
        XCTAssertTrue(path.withLock { $0 }.hasSuffix("/pipelines/ios/builds/88/jobs/j2/log"))
        let noRef = try await forge.pipelineLog(job: PipelineJob(id: "x", name: "x", state: .running), step: nil)
        XCTAssertNil(noRef)
    }

    // MARK: - Azure DevOps

    func testAzureReadsATasksOwnLog() async throws {
        let path = Locked("")
        StubProtocol.handler = { request in
            path.withLock { $0 = request.url?.path ?? "" }
            return (200, Data("2026-10-02T10:00:01.0000000Z Starting task\n".utf8), ["Content-Type": "text/plain"])
        }
        let config = session()
        let credentials = AzureDevOpsCredentials(
            token: "pat", scope: "Mac Fleet", instance: "https://dev.azure.com/acme/")
        let forge = AzureDevOpsForge(
            credentials: ForgeCredentials(
                forge: .azuredevops, token: "pat", scope: "Mac Fleet", instance: "https://dev.azure.com/acme/"),
            labels: ["kinhin"], client: AzureDevOpsClient(credentials: credentials, session: config),
            pool: AzureDevOpsPool(id: 12, name: "Mac Fleet"), account: "ado", listTTL: 0)
        let step = PipelineStep(name: "Run tests", state: .running, logRef: "proj-1|42|7")
        let job = PipelineJob(id: "J1", name: "Compile", state: .running, steps: [step], logRef: "proj-1|42|3")

        let stepLog = try await forge.pipelineLog(job: job, step: step)
        XCTAssertEqual(stepLog?.scope, .step)
        XCTAssertTrue(path.withLock { $0 }.hasSuffix("/proj-1/_apis/build/builds/42/logs/7"))
        _ = try await forge.pipelineLog(job: job, step: nil)
        XCTAssertTrue(path.withLock { $0 }.hasSuffix("/builds/42/logs/3"), "the whole job uses the job's log")
        let noLog = try await forge.pipelineLog(job: job, step: PipelineStep(name: "x", state: .pending))
        XCTAssertNil(noLog, "a step with no log yet has no output")
    }

    // MARK: - Bitbucket

    func testBitbucketReadsAStepsLog() async throws {
        let path = Locked("")
        StubProtocol.handler = { request in
            path.withLock { $0 = request.url?.path ?? "" }
            return (200, Data("+ swift test\n".utf8), [:])
        }
        let credentials = BitbucketCredentials(token: "bbtkn", scope: "acme/api")
        let forge = BitbucketForge(
            credentials: ForgeCredentials(forge: .bitbucket, token: "bbtkn", scope: "acme/api"),
            labels: ["kinhin"], client: BitbucketClient(credentials: credentials, session: session()),
            scope: BitbucketScope(credentials: credentials), workspaceUUID: "{ws-1}", repositoryUUID: nil,
            account: "bb", listTTL: 0)
        let job = PipelineJob(id: "{s2}", name: "Test", state: .running, logRef: "acme/api|{p1}|{s2}")
        let log = try await forge.pipelineLog(job: job, step: nil)
        XCTAssertEqual(log?.text, "+ swift test\n")
        XCTAssertEqual(path.withLock { $0 }, "/2.0/repositories/acme/api/pipelines/{p1}/steps/{s2}/log")
    }

    // MARK: - Gitea

    func testGiteaHasNoOutputApi() async throws {
        let client = GiteaClient(
            credentials: GiteaCredentials(token: "fj", scope: "acme", instance: "https://git.example.com"),
            session: session())
        let forge = GiteaForge(
            credentials: .gitea(token: "fj", scope: "acme", instance: "https://git.example.com"), labels: [],
            client: client, registrationToken: "reg")
        let log = try await forge.pipelineLog(job: PipelineJob(id: "1", name: "b", state: .running), step: nil)
        XCTAssertNil(log)
    }
}
