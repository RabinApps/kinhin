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
        labels: [String] = ["kinhin"], listTTL: TimeInterval = 0
    ) -> BitbucketForge {
        let client = BitbucketClient(
            credentials: BitbucketCredentials(token: "bbtkn", scope: scope), session: session())
        let resolved = BitbucketScope(credentials: BitbucketCredentials(token: "bbtkn", scope: scope))
        return BitbucketForge(
            credentials: ForgeCredentials(forge: .bitbucket, token: "bbtkn", scope: scope),
            labels: labels, client: client, scope: resolved, workspaceUUID: workspaceUUID,
            repositoryUUID: repositoryUUID, account: "bb", listTTL: listTTL)
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
            // Registration first lists runners to clear stale records; only the creations are recorded.
            guard request.httpMethod == "POST" else { return Self.json(#"{"values": [], "next": null}"#) }
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

    /// An instance id reused after a restart would otherwise meet its predecessor's UNREGISTERED record, and a
    /// half-finished registration must not leave the runners it did create behind.
    func testRegistrationClearsStaleRecordsAndCleansUpAfterAFailure() async throws {
        let calls = Mutex<[String]>([])
        let posts = Mutex(0)
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            calls.withLock { $0.append("\(request.httpMethod ?? "") \(path)") }
            switch request.httpMethod {
            case "GET": return Self.runnerList(request, [("{old}", "kinhin-1-r1", "OFFLINE")])
            case "DELETE": return (204, Data(), [:])
            default:
                let count = posts.withLock {
                    $0 += 1
                    return $0
                }
                // The second runner is created without its secret.
                let oauth = count == 1 ? #", "oauth_client": {"id": "c", "secret": "s"}"# : ""
                return Self.json(
                    #"{"uuid": "{new-\#(count)}", "name": "n", "state": {"status": "UNREGISTERED"}\#(oauth)}"#)
            }
        }
        do {
            _ = try await makeForge().registrationTokens(runnerNames: ["kinhin-1-r1", "kinhin-1-r2"], labels: [])
            XCTFail("expected missingOAuthClientSecret")
        } catch {
            XCTAssertEqual(error as? BitbucketError, .missingOAuthClientSecret("kinhin-1-r2"))
        }
        let deletes = calls.withLock { $0 }.filter { $0.hasPrefix("DELETE") }
        XCTAssertTrue(deletes.contains { $0.hasSuffix("/{old}") }, "the stale same-name record is removed first")
        XCTAssertTrue(deletes.contains { $0.hasSuffix("/{new-1}") }, "the runner created before the failure is removed")
        XCTAssertTrue(deletes.contains { $0.hasSuffix("/{new-2}") }, "so is the one created without a secret")
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
            if request.url?.path.hasSuffix("/pipelines-config/runners") != true {
                return Self.json(#"{"values": [], "next": null}"#)  // no active pipelines
            }
            return Self.runnerList(
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

    /// A step payload as `GET .../pipelines/{uuid}/steps` returns it: no `runs_on`.
    private static func step(_ uuid: String, _ name: String?, _ state: String, stage: String? = nil) -> String {
        let nameField = name.map { #""name": "\#($0)", "# } ?? ""
        let stageField = stage.map { #", "stage": {"name": "\#($0)"}"# } ?? ""
        return #"{"uuid": "\#(uuid)", \#(nameField)"state": {"name": "\#(state)"\#(stageField)}}"#
    }

    /// A one-repo Bitbucket: a single pipeline at commit `abc123` with `steps`, the repo's
    /// `bitbucket-pipelines.yml` (nil: the commit has none), and the runner list.
    private static func bitbucket(
        steps: [String], pipelineState: String = "IN_PROGRESS", yml: String?, runners: [(String, String, String)] = []
    ) -> @Sendable (URLRequest) -> (Int, Data, [String: String]) {
        let stepsBody = #"{"values": [\#(steps.joined(separator: ","))], "next": null}"#
        return { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/pipelines-config/runners") { return Self.runnerList(request, runners) }
            if path.hasSuffix("/steps") { return Self.json(stepsBody) }
            if path.hasSuffix("/pipelines") {
                return Self.json(
                    #"""
                    {"values": [{"uuid": "{p1}", "build_number": 7, "repository": {"full_name": "acme/api"},
                      "state": {"name": "\#(pipelineState)"},
                      "target": {"ref_name": "main", "commit": {"hash": "abc123"}}}], "next": null}
                    """#)
            }
            if path.hasSuffix("/src/abc123/bitbucket-pipelines.yml"), let yml {
                return (200, Data(yml.utf8), [:])
            }
            return (404, Data(), [:])
        }
    }

    private static let mixedPipelinesFile = """
        image: node:20
        definitions:
          steps:
            - step: &lint
                name: Lint
                runs-on: [self.hosted, macos]
                script: [npm run lint]
        pipelines:
          default:
            - step: *lint
            - parallel:
                - step:
                    name: Unit tests
                    runs-on:
                      - self.hosted
                      - macos
                    script: [npm test]
                - step:
                    name: Cloud tests
                    script: [npm run cloud]
            - step:
                name: Deploy
                runs-on: self.hosted
                script: [./deploy.sh]
        """

    /// Busy comes from a fresh read of the steps, not from a flag that only `runningJobs()` ever set: the exit
    /// watch calls `runners()` alone, so the flag stayed stale (busy forever, or idle under a running step).
    func testRunnersAreBusyWhileASelfHostedStepRuns() async throws {
        StubProtocol.handler = Self.bitbucket(
            steps: [Self.step("{s1}", "Lint", "IN_PROGRESS")], yml: Self.mixedPipelinesFile,
            runners: [("{r-1}", "kinhin-1", "ONLINE")])
        let busy = try await makeForge(scope: "acme/api").runners()
        XCTAssertEqual(busy.first?.busy, true, "steps do not name their runner; a running step marks the scope busy")

        StubProtocol.handler = Self.bitbucket(
            steps: [Self.step("{s1}", "Lint", "COMPLETED")], pipelineState: "COMPLETED", yml: Self.mixedPipelinesFile,
            runners: [("{r-1}", "kinhin-1", "ONLINE")])
        let idle = try await makeForge(scope: "acme/api").runners()
        XCTAssertEqual(idle.first?.busy, false)
    }

    func testRunnersAreNotBusyForACloudStep() async throws {
        StubProtocol.handler = Self.bitbucket(
            steps: [Self.step("{s1}", "Cloud tests", "IN_PROGRESS")], yml: Self.mixedPipelinesFile,
            runners: [("{r-1}", "kinhin-1", "ONLINE")])
        let runners = try await makeForge(scope: "acme/api").runners()
        XCTAssertEqual(runners.first?.busy, false, "a cloud-runner step keeps no self-hosted instance alive")
    }

    /// Only steps that name `self.hosted` in the pipeline file are demand: cloud steps and future steps (behind a
    /// running one) are not, whatever pipeline they belong to.
    func testOnlySelfHostedWaitingStepsCountAsDemand() async throws {
        StubProtocol.handler = Self.bitbucket(
            steps: [
                Self.step("{s1}", "Lint", "PENDING"),
                Self.step("{s2}", "Unit tests", "PENDING"),
                Self.step("{s3}", "Cloud tests", "PENDING"),
                Self.step("{s4}", "Deploy", "PENDING"),
            ], pipelineState: "PENDING", yml: Self.mixedPipelinesFile)
        let queued = try await makeForge(scope: "acme/api").queuedJobs()
        XCTAssertEqual(queued.map(\.name), ["Lint", "Unit tests", "Deploy"])
        XCTAssertEqual(queued.first?.repository, "acme/api")
        XCTAssertEqual(queued.first?.labels, ["self.hosted", "macos"])
    }

    func testStepsBehindARunningStepOrPausedAreNotYetDemand() async throws {
        StubProtocol.handler = Self.bitbucket(
            steps: [
                Self.step("{s1}", "Lint", "IN_PROGRESS"),
                Self.step("{s2}", "Unit tests", "PENDING"),
            ], yml: Self.mixedPipelinesFile)
        let queued = try await makeForge(scope: "acme/api").queuedJobs()
        XCTAssertTrue(queued.isEmpty, "the next step needs a runner only once the running one finishes")

        StubProtocol.handler = Self.bitbucket(
            steps: [Self.step("{s1}", "Deploy", "PENDING", stage: "PAUSED")], yml: Self.mixedPipelinesFile)
        let paused = try await makeForge(scope: "acme/api").queuedJobs()
        XCTAssertTrue(paused.isEmpty, "a paused step waits for a person, not a runner")
    }

    func testPipelineWithoutAPipelinesFileIsNotDemand() async throws {
        StubProtocol.handler = Self.bitbucket(steps: [Self.step("{s1}", "Build", "PENDING")], yml: nil)
        let queued = try await makeForge(scope: "acme/api").queuedJobs()
        XCTAssertTrue(queued.isEmpty)
    }

    /// An unreadable pipeline file must not strand a pipeline: its steps count, an idle runner times out.
    func testUnreadablePipelinesFileFailsOpen() async throws {
        StubProtocol.handler = { request in
            if request.url?.path.contains("/src/") == true { return (500, Data(), [:]) }
            return Self.bitbucket(steps: [Self.step("{s1}", "Build", "PENDING")], pipelineState: "PENDING", yml: nil)(
                request)
        }
        let queued = try await makeForge(scope: "acme/api").queuedJobs()
        XCTAssertEqual(queued.count, 1)
    }

    /// A token that cannot list runners (403) reports none, remembers that, and the engine reads running steps
    /// instead of retrying the list to its six-hour deadline.
    func testForbiddenRunnerListFallsBackToRunningStepActivity() async throws {
        let listRequests = Mutex(0)
        let steps = Mutex([Self.step("{s1}", "Lint", "IN_PROGRESS")])
        StubProtocol.handler = { request in
            if request.url?.path.hasSuffix("/pipelines-config/runners") == true {
                listRequests.withLock { $0 += 1 }
                return (403, Data(), [:])
            }
            return Self.bitbucket(steps: steps.withLock { $0 }, yml: Self.mixedPipelinesFile)(request)
        }
        let forge = makeForge(scope: "acme/api")
        let runners = try await forge.runners()
        XCTAssertTrue(runners.isEmpty)
        let activity = try await forge.unlistedRunnerActivity(fresh: false)
        XCTAssertEqual(activity, 1)
        _ = try await forge.runners()
        XCTAssertEqual(listRequests.withLock { $0 }, 1, "the 403 is remembered; the list is not asked again")
        steps.withLock { $0 = [Self.step("{s1}", "Lint", "COMPLETED")] }
        let after = try await forge.unlistedRunnerActivity(fresh: true)
        XCTAssertEqual(after, 0, "a fresh ask re-reads the steps")
    }

    func testAListedScopeHasNoUnlistedActivity() async throws {
        StubProtocol.handler = Self.bitbucket(
            steps: [Self.step("{s1}", "Lint", "IN_PROGRESS")], yml: Self.mixedPipelinesFile,
            runners: [("{r-1}", "kinhin-1", "ONLINE")])
        let forge = makeForge(scope: "acme/api")
        _ = try await forge.runners()
        let activity = try await forge.unlistedRunnerActivity(fresh: false)
        XCTAssertNil(activity)
    }

    /// The repository list is cached apart from the pipelines, and a poll that hits the step cache sends nothing.
    func testRepositoryListAndStepsAreCachedBetweenPolls() async throws {
        let requests = Mutex<[String]>([])
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            requests.withLock { $0.append(path) }
            if path == "/2.0/repositories/acme" {
                return Self.json(
                    #"{"values": [{"full_name": "acme/api", "updated_on": "2026-02-14T18:42:09.987654+00:00"}]}"#)
            }
            return Self.bitbucket(
                steps: [Self.step("{s1}", "Lint", "PENDING")], pipelineState: "PENDING",
                yml: Self.mixedPipelinesFile, runners: [("{r-1}", "kinhin-1", "ONLINE")])(request)
        }
        let forge = makeForge(listTTL: 60)
        _ = try await forge.queuedJobs()
        _ = try await forge.runningJobs()
        _ = try await forge.runners()
        _ = try await forge.queuedJobs()
        let sent = requests.withLock { $0 }
        XCTAssertEqual(sent.filter { $0 == "/2.0/repositories/acme" }.count, 1, "\(sent)")
        XCTAssertEqual(sent.filter { $0.hasSuffix("/pipelines") }.count, 1, "\(sent)")
        XCTAssertEqual(sent.filter { $0.hasSuffix("/bitbucket-pipelines.yml") }.count, 1, "\(sent)")
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
