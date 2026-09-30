import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class GitLabClientTests: XCTestCase {
    private func makeClient(scope: String = "acme/api", instance: String? = nil) -> GitLabClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return GitLabClient(
            credentials: GitLabCredentials(token: "glpat", scope: scope, instance: instance),
            session: URLSession(configuration: config))
    }

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - URLs and headers

    func testURLsEncodeNestedPathsAndKeepRelativeRoots() throws {
        let client = makeClient(scope: "grp/sub/proj", instance: "https://example.com/gitlab/")
        let url = try client.url("/projects/\(GitLabClient.encodePathSegment("grp/sub/proj"))", [])
        XCTAssertEqual(url.absoluteString, "https://example.com/gitlab/api/v4/projects/grp%2Fsub%2Fproj")
        XCTAssertEqual(
            try makeClient().url("/version", []).absoluteString, "https://gitlab.com/api/v4/version",
            "gitlab.com is the default instance")
    }

    func testInstanceValidation() {
        XCTAssertNoThrow(try GitLabCredentials.validate(instance: "https://gitlab.example.com"))
        XCTAssertNoThrow(try GitLabCredentials.validate(instance: "http://10.0.0.5:8080/gitlab"))
        XCTAssertThrowsError(try GitLabCredentials.validate(instance: "gitlab.example.com"))
        XCTAssertThrowsError(try GitLabCredentials.validate(instance: "https://gitlab.example.com/api/v4"))
        XCTAssertTrue(GitLabCredentials.isValidScope("grp/sub/proj"))
        XCTAssertFalse(GitLabCredentials.isValidScope("grp//proj"))
        XCTAssertFalse(GitLabCredentials.isValidScope(""))
    }

    func testSendsPrivateTokenHeader() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "PRIVATE-TOKEN"), "glpat")
            return (200, Data(#"{"version":"17.4.1-ee"}"#.utf8), [:])
        }
        let version = try await makeClient().version()
        XCTAssertEqual(version, "17.4.1-ee")
    }

    // MARK: - Scope resolution

    func testResolvesAProject() async throws {
        StubProtocol.handler = { request in
            XCTAssertTrue(request.url!.absoluteString.hasSuffix("/api/v4/projects/acme%2Fapi"))
            return (200, Data(#"{"id":7,"path_with_namespace":"acme/api"}"#.utf8), [:])
        }
        let scope = try await makeClient().resolveScope()
        XCTAssertEqual(scope, .project(id: 7, path: "acme/api"))
    }

    func testFallsBackToAGroup() async throws {
        StubProtocol.handler = { request in
            if request.url!.path.contains("/projects/") { return (404, Data(), [:]) }
            return (200, Data(#"{"id":3,"full_path":"acme/platform"}"#.utf8), [:])
        }
        let scope = try await makeClient(scope: "acme/platform").resolveScope()
        XCTAssertEqual(scope, .group(id: 3, path: "acme/platform"))
    }

    func testNeitherProjectNorGroupIsNotFound() async {
        StubProtocol.handler = { _ in (404, Data(), [:]) }
        do {
            _ = try await makeClient().resolveScope()
            XCTFail("expected notFound")
        } catch let error as GitLabError {
            XCTAssertEqual(error, .notFound("project or group 'acme/api'"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Runners

    func testCreateRunnerPostsTypeScopeAndTags() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.path.hasSuffix("/api/v4/user/runners"))
            let body = request.bodyStreamData()
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            XCTAssertEqual(json?["runner_type"] as? String, "group_type")
            XCTAssertEqual(json?["group_id"] as? Int, 3)
            XCTAssertEqual(json?["description"] as? String, "kinhin-1")
            XCTAssertEqual(json?["tag_list"] as? [String], ["macos", "arm64"])
            XCTAssertEqual(json?["run_untagged"] as? Bool, false)
            return (201, Data(#"{"id":99,"token":"glrt-abc"}"#.utf8), [:])
        }
        let created = try await makeClient().createRunner(
            in: .group(id: 3, path: "acme"), name: "kinhin-1", tags: ["macos", "arm64"])
        XCTAssertEqual(created, GitLabCreatedRunner(id: 99, token: "glrt-abc"))
    }

    func testListRunnersFollowsPagination() async throws {
        StubProtocol.handler = { request in
            XCTAssertTrue(request.url!.query!.contains("type=project_type"))
            if request.url!.query!.contains("page=2") {
                return (200, Data(#"[{"id":2,"description":"kinhin-2","status":"never_contacted"}]"#.utf8), [:])
            }
            return (
                200, Data(#"[{"id":1,"description":"kinhin-1","status":"online"}]"#.utf8), ["X-Next-Page": "2"]
            )
        }
        let runners = try await makeClient().listRunners(in: .project(id: 7, path: "acme/api"))
        XCTAssertEqual(runners.map(\.id), [1, 2])
        XCTAssertEqual(runners.map(\.hasContacted), [true, false])
    }

    // MARK: - Jobs

    func testGroupJobsFanOutOverRecentProjectsAndSkipUnreadableOnes() async throws {
        StubProtocol.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/groups/3/projects") {
                XCTAssertTrue(request.url!.query!.contains("include_subgroups=true"))
                XCTAssertTrue(request.url!.query!.contains("last_activity_after="))
                let body = """
                    [{"id":10,"path_with_namespace":"acme/api"},
                     {"id":11,"path_with_namespace":"acme/web"},
                     {"id":12,"path_with_namespace":"acme/secret"}]
                    """
                return (200, Data(body.utf8), [:])
            }
            XCTAssertTrue(
                request.url!.query!.contains("scope%5B%5D=pending") || request.url!.query!.contains("scope[]=pending"))
            if path.hasSuffix("/projects/10/jobs") {
                return (200, Data(#"[{"id":1,"name":"build","tag_list":["macos"],"runner":null}]"#.utf8), [:])
            }
            if path.hasSuffix("/projects/11/jobs") {
                return (200, Data(#"[{"id":2,"name":"lint","tag_list":[]}]"#.utf8), [:])
            }
            return (403, Data(), [:])
        }
        let jobs = try await makeClient(scope: "acme").jobs(.pending, in: .group(id: 3, path: "acme"))
        XCTAssertEqual(
            jobs,
            [
                GitLabJob(id: 1, name: "build", tags: ["macos"], project: "acme/api", runnerDescription: nil),
                GitLabJob(id: 2, name: "lint", tags: [], project: "acme/web", runnerDescription: nil),
            ])
    }

    func testRunningJobsCarryTheirRunner() async throws {
        StubProtocol.handler = { _ in
            (
                200,
                Data(#"[{"id":5,"name":"test","tag_list":["macos"],"runner":{"description":"kinhin-1"}}]"#.utf8),
                [:]
            )
        }
        let jobs = try await makeClient().jobs(.running, in: .project(id: 7, path: "acme/api"))
        XCTAssertEqual(jobs.first?.runnerDescription, "kinhin-1")
        XCTAssertEqual(jobs.first?.project, "acme/api")
    }

    // MARK: - Errors

    func testErrorMapping() async {
        for (status, expected) in [(401, GitLabError.unauthorized), (404, .notFound("/version"))] {
            StubProtocol.handler = { _ in (status, Data(), [:]) }
            do {
                _ = try await makeClient().version()
                XCTFail("expected \(expected)")
            } catch let error as GitLabError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
        XCTAssertTrue(GitLabClient.isTransient(GitLabError.http(502, "")))
        XCTAssertTrue(GitLabClient.isTransient(GitLabError.http(429, "")))
        XCTAssertFalse(GitLabClient.isTransient(GitLabError.unauthorized))
        XCTAssertEqual(ErrorCategory(GitLabError.unauthorized), .auth)
    }
}

extension URLRequest {
    /// URLProtocol receives POST bodies as a stream; read it back for asserts.
    fileprivate func bodyStreamData() -> Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
