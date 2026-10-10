import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The Bitbucket forge against a small simulated Bitbucket (runners,
/// pipelines and their steps) behind `StubProtocol`: its mapping onto the
/// Forge surface and the per-runner credential capture.
final class BitbucketForgeTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeForge(
        scope: String = "acme", workspaceUUID: String = "{ws-1}", repositoryUUID: String? = nil,
        labels: [String] = ["kinhin"]
    ) -> BitbucketForge {
        let client = BitbucketClient(
            credentials: BitbucketCredentials(token: "bbtkn", scope: scope), session: session())
        let resolved = BitbucketScope(credentials: BitbucketCredentials(token: "bbtkn", scope: scope))
        return BitbucketForge(
            credentials: ForgeCredentials(forge: .bitbucket, token: "bbtkn", scope: scope),
            labels: labels, client: client, scope: resolved, workspaceUUID: workspaceUUID,
            repositoryUUID: repositoryUUID, account: "bb", listTTL: 0)
    }

    // MARK: - Forge surface

    func testIdentityAndBehavior() {
        let forge = makeForge()
        XCTAssertEqual(forge.id, .bitbucket)
        XCTAssertEqual(forge.account, "bb")
        XCTAssertEqual(forge.registration, .perRunner)
        XCTAssertEqual(forge.exitSemantics, .idleGrace, "runners stay registered across steps")
        XCTAssertEqual(forge.registrationURL(), "https://api.bitbucket.org")
        XCTAssertTrue(forge.attributesByRepo, "a workspace scope attributes by repo")
        XCTAssertFalse(
            makeForge(scope: "acme/api").attributesByRepo, "a repository scope has nothing to break down")
    }

    func testRegistrationCreatesOneRunnerPerNameWithTheFleetLabels() async throws {
        let created = Mutex<[[String]]>([])
        StubProtocol.handler = { request in
            guard request.httpMethod == "POST", request.url?.path == "/2.0/workspaces/acme/pipelines-config/runners"
            else {
                return (404, Data(), [:])
            }
            let body = (try? JSONSerialization.jsonObject(with: Self.bodyData(request))) as? [String: Any] ?? [:]
            let name = body["name"] as? String ?? ""
            let labels = body["labels"] as? [String] ?? []
            created.withLock { $0.append(labels) }
            return Self.json(
                #"{"uuid": "{r-1}", "name": "\#(name)", "state": {"status": "UNREGISTERED"}, "oauth_client": {"id": "cli-1", "secret": "sec-\#(name)"}}"#
            )
        }
        let forge = makeForge(labels: ["kinhin"])
        let tokens = try await forge.registrationTokens(runnerNames: ["kinhin-1-r1", "kinhin-1-r2"], labels: [])
        XCTAssertEqual(
            Set(tokens.keys), ["kinhin-1-r1", "kinhin-1-r2"],
            "each runner is created on the forge with its own OAuth credentials")
        XCTAssertEqual(created.withLock { $0 }.count, 2)
        XCTAssertEqual(
            created.withLock { $0 }.first, ["self.hosted", "macos", "kinhin"],
            "runners register with self.hosted + the platform marker + the account's labels")
    }

    /// The pool's labels reach the forge-side runner (they were dropped, leaving only the account's), and the
    /// platform label follows the pool: a Docker pool is `linux.shell`, never `macos` from the fleet's defaults.
    func testPoolLabelsDecideThePlatformAndReachTheRunner() async throws {
        let created = Mutex<[[String]]>([])
        StubProtocol.handler = { request in
            let body = (try? JSONSerialization.jsonObject(with: Self.bodyData(request))) as? [String: Any] ?? [:]
            created.withLock { $0.append(body["labels"] as? [String] ?? []) }
            return Self.json(
                #"{"uuid": "{r-1}", "name": "n", "state": {"status": "UNREGISTERED"}, "oauth_client": {"id": "c", "secret": "s"}}"#
            )
        }
        let forge = makeForge(labels: ["team"])
        _ = try await forge.registrationTokens(
            runnerNames: ["kinhin-1"], labels: ["self-hosted", "macos", "x64", "kinhin-docker"])
        _ = try await forge.registrationTokens(runnerNames: ["kinhin-2"], labels: ["self-hosted", "macos", "arm64"])
        let labels = created.withLock { $0 }
        XCTAssertEqual(labels[0], ["self.hosted", "linux.shell", "team", "self-hosted", "x64", "kinhin-docker"])
        XCTAssertEqual(labels[1], ["self.hosted", "macos", "team", "self-hosted", "arm64"])
    }

    func testPlatformMarkerKnowsLinuxGuestsFromTheirLabels() {
        XCTAssertEqual(BitbucketForge.platformMarker(forPoolLabels: ["self-hosted", "macos"]), "macos")
        XCTAssertEqual(BitbucketForge.platformMarker(forPoolLabels: ["kinhin-host"]), "macos")
        XCTAssertEqual(BitbucketForge.platformMarker(forPoolLabels: ["arm64", "Linux"]), "linux.shell")
        XCTAssertEqual(BitbucketForge.platformMarker(forPoolLabels: ["kinhin-docker"]), "linux.shell")
    }

    func testRunnerLabelsAddSelfHostedAndPlatform() {
        XCTAssertEqual(
            BitbucketForge.runnerLabels(accountLabels: ["kinhin", "xcode=16"], platform: "macos"),
            ["self.hosted", "macos", "kinhin", "xcode=16"])
        XCTAssertEqual(
            BitbucketForge.platformMarker(forPoolLabels: ["arm64", "kinhin-container"]), "linux.shell")
        XCTAssertEqual(BitbucketForge.platformMarker(forPoolLabels: []), "macos")
    }

    func testCredentialBundleCarriesEverythingTheStartCommandNeeds() {
        let forge = makeForge(scope: "acme/api", workspaceUUID: "{ws}", repositoryUUID: "{repo}")
        let bundle = forge.credentialBundle(
            runner: BitbucketRunner(
                uuid: "{r}", name: "kinhin-1", status: "UNREGISTERED",
                oauthClient: .init(id: "cli", secret: "sec")))
        XCTAssertEqual(bundle, "{ws}|{repo}|{r}|cli|sec")
        XCTAssertNil(
            forge.credentialBundle(
                runner: BitbucketRunner(uuid: "{r}", name: "n", status: "UNREGISTERED", oauthClient: nil)),
            "a create response without the OAuth secret cannot register anything")
    }

    // MARK: - Runners and demand

    func testRunnersMapToTheUnifiedShape() async throws {
        StubProtocol.handler = { request in
            Self.runnerList(
                request,
                [
                    ("{r-1}", "kinhin-1", "ONLINE"),
                    ("{r-2}", "kinhin-2", "OFFLINE"),
                ])
        }
        let forge = makeForge()
        let runners = try await forge.runners()
        XCTAssertEqual(
            runners,
            [
                ForgeRunner(id: "{r-1}", name: "kinhin-1", busy: false),
                ForgeRunner(id: "{r-2}", name: "kinhin-2", busy: false, online: false),
            ])
    }

    func testRunningStepsMarkTheScopeBusy() async throws {
        StubProtocol.handler = { request in
            if request.url?.path.hasSuffix("/pipelines-config/runners") == true {
                return Self.runnerList(request, [("{r-1}", "kinhin-1", "ONLINE")])
            }
            if request.url?.path.hasSuffix("/pipelines") == true {
                return Self.json(
                    #"{"values": [{"uuid": "{p1}", "repository": {"full_name": "acme/api"}, "state": {"name": "IN_PROGRESS"}}], "next": null}"#
                )
            }
            if request.url?.path.hasSuffix("/steps") == true {
                return Self.json(
                    #"{"values": [{"uuid": "{s1}", "state": {"name": "IN_PROGRESS"}}], "next": null}"#)
            }
            return (404, Data(), [:])
        }
        let forge = makeForge(scope: "acme/api")
        let before = try await forge.runners()
        XCTAssertEqual(before.first?.busy, false)
        _ = try await forge.runningJobs()
        let after = try await forge.runners()
        XCTAssertEqual(after.first?.busy, true, "steps do not name their runner; a running step marks the scope busy")
    }

    func testQueuedStepsOfTheScopeCountAsDemand() async throws {
        let forge = makeForge(scope: "acme/api")
        StubProtocol.handler = { request in
            if request.url?.path.hasSuffix("/repositories/acme/api/pipelines") == true {
                return Self.json(
                    #"""
                    {"values": [
                      {"uuid": "{p1}", "repository": {"full_name": "acme/api"}, "state": {"name": "PENDING"}},
                      {"uuid": "{p2}", "repository": {"full_name": "acme/api"}, "state": {"name": "COMPLETED"}}
                    ], "next": null}
                    """#
                )
            }
            if request.url?.path.contains("steps") == true {
                return Self.json(
                    #"{"values": [{"uuid": "{s1}", "state": {"name": "PENDING"}}], "next": null}"#)
            }
            return (404, Data(), [:])
        }
        let queued = try await forge.queuedJobs()
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.repository, "acme/api")
    }

    func testDeletingARunnerGoesToTheForge() async throws {
        let deleted = Mutex<[String]>([])
        StubProtocol.handler = { request in
            deleted.withLock { $0.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")") }
            return (204, Data(), [:])
        }
        try await makeForge().deleteRunner(id: "{r-1}")
        XCTAssertEqual(
            deleted.withLock { $0 }.first?.contains("DELETE /2.0/workspaces/acme/pipelines-config/runners/"),
            true, "the runner UUID is deleted at the workspace's runner endpoint")
    }

    // MARK: - Helpers

    private static func json(_ body: String) -> (Int, Data, [String: String]) {
        (200, Data(body.utf8), ["Content-Type": "application/json; charset=utf-8"])
    }

    /// The runners endpoint (workspace or repo scope), one page.
    private static func runnerList(_ request: URLRequest, _ runners: [(String, String, String)])
        -> (Int, Data, [String: String])
    {
        _ = request
        let rows = runners.map { runner in
            #"{"uuid": "\#(runner.0)", "name": "\#(runner.1)", "state": {"status": "\#(runner.2)"}}"#
        }
        return (200, Data(#"{"values": [\#(rows.joined(separator: ","))], "next": null}"#.utf8), [:])
    }

    /// A request body, whether it was captured as data or as a stream.
    private static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
