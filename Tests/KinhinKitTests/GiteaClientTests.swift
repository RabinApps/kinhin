import XCTest
@testable import KinhinKit

final class GiteaClientTests: XCTestCase {
    private func makeClient(instance: String = "https://gitea.example.com") -> GiteaClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return GiteaClient(
            credentials: GiteaCredentials(token: "gt", scope: "acme/api", instance: instance),
            session: URLSession(configuration: config)
        )
    }

    func testListRepositoriesReadsWrappedResponse() async throws {
        StubProtocol.handler = { request in
            XCTAssertTrue(request.url!.path.hasPrefix("/api/v1/repos/search"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token gt")
            let body = """
            {"ok":true,"data":[
              {"full_name":"acme/api","private":false,"has_actions":true},
              {"full_name":"acme/web","private":true,"has_actions":false}
            ]}
            """
            return (200, Data(body.utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let repos = try await makeClient().listRepositories()
        // Actions-enabled first, then alphabetical.
        XCTAssertEqual(repos.map(\.fullName), ["acme/api", "acme/web"])
        XCTAssertEqual(repos[1].isPrivate, true)
    }

    func testListRepositoriesReadsBareArrayResponse() async throws {
        StubProtocol.handler = { request in
            // A bare top-level JSON array (older Gitea) is not valid inside
            // the wrapped shape's {ok,data} — exercise the fallback path.
            let body = """
            [{"full_name":"acme/only","private":false,"has_actions":true}]
            """
            return (200, Data(body.utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let repos = try await makeClient().listRepositories()
        XCTAssertEqual(repos.map(\.fullName), ["acme/only"])
    }

    func testListRepositoriesSurfacesUnauthorized() async throws {
        StubProtocol.handler = { _ in (401, Data("no".utf8), [:]) }
        defer { StubProtocol.handler = nil }
        do {
            _ = try await makeClient().listRepositories()
            XCTFail("expected unauthorized")
        } catch let error as GiteaError {
            XCTAssertEqual(error, .unauthorized)
        }
    }
}
