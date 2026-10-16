import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Repo-file reads per forge: the request shape (path, ref, encoding), the
/// `.kinhin/config.yml`-then-`.kinhin.yml` order, and the "no file → nil" contract.
final class ProjectFileFetchTests: XCTestCase {
    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        StubProtocol.handler = nil
    }

    private let body = Data("toolchains:\n  specs: [go@1.22.5]\n".utf8)

    func testGitHubReadsRawFileAtRef() async throws {
        let seen = Locked<(path: String, query: String, accept: String)>(("", "", ""))
        StubProtocol.handler = { [body] request in
            seen.withLock {
                $0 = (
                    request.url?.path ?? "", request.url?.query ?? "",
                    request.value(forHTTPHeaderField: "Accept") ?? ""
                )
            }
            return (200, body, [:])
        }
        let client = GitHubClient(credentials: GitHubCredentials(token: "t", scope: "acme"), session: session)
        let data = try await client.projectFile(repository: "acme/api", ref: "feature/x y")
        XCTAssertEqual(data, body)
        let request = seen.withLock { $0 }
        XCTAssertEqual(request.path, "/repos/acme/api/contents/.kinhin/config.yml")
        XCTAssertEqual(request.query, "ref=feature%2Fx%20y")
        XCTAssertEqual(request.accept, "application/vnd.github.raw+json")
    }

    func testGitHubFallsBackToTheOlderFileName() async throws {
        let paths = Locked<[String]>([])
        StubProtocol.handler = { [body] request in
            let path = request.url?.path ?? ""
            paths.withLock { $0.append(path) }
            return path.hasSuffix("/.kinhin.yml") ? (200, body, [:]) : (404, Data(), [:])
        }
        let client = GitHubClient(credentials: GitHubCredentials(token: "t", scope: "acme"), session: session)
        let data = try await client.projectFile(repository: "acme/api", ref: "main")
        XCTAssertEqual(data, body)
        XCTAssertEqual(
            paths.withLock { $0 },
            ["/repos/acme/api/contents/.kinhin/config.yml", "/repos/acme/api/contents/.kinhin.yml"])
    }

    func testTheNewFileWinsAndTheOlderOneIsNotFetched() async throws {
        let paths = Locked<[String]>([])
        StubProtocol.handler = { [body] request in
            paths.withLock { $0.append(request.url?.path ?? "") }
            return (200, body, [:])
        }
        let client = GiteaClient(
            credentials: GiteaCredentials(token: "t", scope: "acme/api", instance: "https://git.example.com"),
            session: session)
        _ = try await client.projectFile(repository: "acme/api", ref: nil)
        XCTAssertEqual(paths.withLock { $0 }, ["/api/v1/repos/acme/api/raw/.kinhin/config.yml"])
    }

    func testGitLabFallsBackToTheOlderFileName() async throws {
        let paths = Locked<[String]>([])
        StubProtocol.handler = { [body] request in
            let path =
                request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } ?? ""
            paths.withLock { $0.append(path) }
            return path.contains("files/.kinhin.yml/") ? (200, body, [:]) : (404, Data(), [:])
        }
        let client = GitLabClient(
            credentials: GitLabCredentials(token: "t", scope: "group", instance: "https://gitlab.example.com"),
            session: session)
        let data = try await client.projectFile(repository: "group/app", ref: "main")
        XCTAssertEqual(data, body)
        XCTAssertEqual(paths.withLock { $0 }.count, 2)
    }

    func testGitHubWithoutRefReadsTheDefaultBranch() async throws {
        let query = Locked<String?>("unset")
        StubProtocol.handler = { [body] request in
            query.withLock { $0 = request.url?.query }
            return (200, body, [:])
        }
        let client = GitHubClient(credentials: GitHubCredentials(token: "t", scope: "acme"), session: session)
        _ = try await client.projectFile(repository: "acme/api", ref: nil)
        XCTAssertNil(query.withLock { $0 })
    }

    func testGitHubMissingFileIsNil() async throws {
        StubProtocol.handler = { _ in (404, Data("{\"message\":\"Not Found\"}".utf8), [:]) }
        let client = GitHubClient(credentials: GitHubCredentials(token: "t", scope: "acme"), session: session)
        let data = try await client.projectFile(repository: "acme/api", ref: "main")
        XCTAssertNil(data)
    }

    func testGitHubRejectsAPathEscapingRepositoryName() async {
        StubProtocol.handler = { _ in
            XCTFail("no request may be sent for an invalid repository")
            return (404, Data(), [:])
        }
        let client = GitHubClient(credentials: GitHubCredentials(token: "t", scope: "acme"), session: session)
        do {
            _ = try await client.projectFile(repository: "acme/../admin", ref: nil)
            XCTFail("expected an error")
        } catch {}
    }

    func testGiteaReadsRawFile() async throws {
        let seen = Locked<(path: String, query: String)>(("", ""))
        StubProtocol.handler = { [body] request in
            seen.withLock { $0 = (request.url?.path ?? "", request.url?.query ?? "") }
            return (200, body, [:])
        }
        let client = GiteaClient(
            credentials: GiteaCredentials(token: "t", scope: "acme/api", instance: "https://git.example.com"),
            session: session)
        let data = try await client.projectFile(repository: "acme/api", ref: "v1.0")
        XCTAssertEqual(data, body)
        XCTAssertEqual(seen.withLock { $0 }.path, "/api/v1/repos/acme/api/raw/.kinhin/config.yml")
        XCTAssertEqual(seen.withLock { $0 }.query, "ref=v1.0")
    }

    func testGiteaMissingFileIsNil() async throws {
        StubProtocol.handler = { _ in (404, Data(), [:]) }
        let client = GiteaClient(
            credentials: GiteaCredentials(token: "t", scope: "acme/api", instance: "https://git.example.com"),
            session: session)
        let data = try await client.projectFile(repository: "acme/api", ref: nil)
        XCTAssertNil(data)
    }

    func testGitLabEncodesTheProjectPathAndDefaultsToHEAD() async throws {
        let seen = Locked<(path: String, query: String)>(("", ""))
        StubProtocol.handler = { [body] request in
            seen.withLock {
                $0 = (
                    request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath }
                        ?? "", request.url?.query ?? ""
                )
            }
            return (200, body, [:])
        }
        let client = GitLabClient(
            credentials: GitLabCredentials(token: "t", scope: "group/sub", instance: "https://gitlab.example.com"),
            session: session)
        let data = try await client.projectFile(repository: "group/sub/app", ref: nil)
        XCTAssertEqual(data, body)
        XCTAssertEqual(
            seen.withLock { $0 }.path, "/api/v4/projects/group%2Fsub%2Fapp/repository/files/.kinhin%2Fconfig.yml/raw")
        XCTAssertEqual(seen.withLock { $0 }.query, "ref=HEAD")
    }

    func testGitLabMissingFileIsNil() async throws {
        StubProtocol.handler = { _ in (404, Data(), [:]) }
        let client = GitLabClient(
            credentials: GitLabCredentials(token: "t", scope: "group", instance: "https://gitlab.example.com"),
            session: session)
        let data = try await client.projectFile(repository: "group/app", ref: "main")
        XCTAssertNil(data)
    }

    func testTheOtherForgesNeverReadAFile() async throws {
        let buildkite = BuildkiteCredentials(token: "t", scope: "org")
        XCTAssertEqual(buildkite.scope, "org")
        // The protocol default is "no file API": no network involved.
        struct NoFileForge: Forge {
            var id: ForgeID { .buildkite }
            var name: String { "buildkite" }
            var credentials: ForgeCredentials { .github(token: "", scope: "a/b") }
            var labels: [String] { [] }
            var registration: ForgeRegistration { .sharedLongLived }
            var exitSemantics: ForgeExitSemantics { .deregisters }
            func registrationURL() -> String { "" }
            func mintRegistrationToken() async throws -> String { "" }
            func runners() async throws -> [ForgeRunner] { [] }
            func deleteRunner(id: String) async throws {}
            func queuedJobs() async throws -> [ForgeJob] { [] }
            func runningJobs() async throws -> [ForgeJob] { [] }
        }
        let file = try await NoFileForge().projectFile(repository: "a/b", ref: nil)
        XCTAssertNil(file)
    }
}
