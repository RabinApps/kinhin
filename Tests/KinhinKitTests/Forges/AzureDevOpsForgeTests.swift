import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class AzureDevOpsForgeTests: XCTestCase {
    private let pool = AzureDevOpsPool(id: 12, name: "Mac Fleet")

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeForge(
        labels: [String] = ["kinhin"], offlineGrace: TimeInterval = 60, idleOfflineGrace: TimeInterval? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> AzureDevOpsForge {
        let credentials = AzureDevOpsCredentials(
            token: "pat", scope: "Mac Fleet", instance: "https://dev.azure.com/acme/")
        return AzureDevOpsForge(
            credentials: ForgeCredentials(
                forge: .azuredevops, token: "pat", scope: "Mac Fleet", instance: "https://dev.azure.com/acme/"),
            labels: labels, client: AzureDevOpsClient(credentials: credentials, session: session()), pool: pool,
            account: "ado", listTTL: 0, offlineGrace: offlineGrace,
            idleOfflineGrace: idleOfflineGrace ?? offlineGrace, now: now)
    }

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Demands

    func testDemandsMustAskForEveryLabel() {
        XCTAssertTrue(AzureDevOpsForge.demands(["kinhin", "Agent.Version -gtVersion 3.0"], include: ["kinhin"]))
        XCTAssertTrue(AzureDevOpsForge.demands(["Kinhin -equals true"], include: ["kinhin"]), "names ignore case")
        XCTAssertTrue(AzureDevOpsForge.demands(["xcode -equals 16"], include: ["xcode=16"]))
        XCTAssertFalse(AzureDevOpsForge.demands(["xcode -equals 15"], include: ["xcode=16"]))
        XCTAssertFalse(AzureDevOpsForge.demands(["xcode"], include: ["xcode=16"]), "a value label needs -equals")
        XCTAssertFalse(AzureDevOpsForge.demands(["Agent.Version -gtVersion 3.0"], include: ["kinhin"]))
        XCTAssertTrue(AzureDevOpsForge.demands([], include: []), "no labels: the whole pool is kinhin's")
    }

    func testLabelsBecomeCapabilityEnvironment() {
        XCTAssertEqual(AzureDevOpsForge.capabilityEnvironment(["kinhin", "xcode=16"]), ["kinhin=true", "xcode=16"])
    }

    /// A pool's runtime marker (`kinhin-docker`) has a hyphen, which `export` and the agent's environment-variable
    /// capabilities refuse: it becomes `kinhin_docker=true`, and the pool's labels join the account's.
    func testPoolMarkersBecomeValidCapabilities() {
        XCTAssertEqual(
            AzureDevOpsForge.capabilityEnvironment(
                ["kinhin"], poolLabels: ["kinhin", "kinhin-docker", "xcode=16", "9lives", "---", "self-hosted"]),
            ["kinhin=true", "kinhin_docker=true", "xcode=16", "_9lives=true", "self_hosted=true"])
        XCTAssertEqual(
            AzureDevOpsForge.capabilityEnvironment(["xcode=16"], poolLabels: ["xcode=15"]), ["xcode=16"],
            "the account's value wins")
        XCTAssertEqual(AzureDevOpsForge.capabilityEnvironment([], poolLabels: ["a=b\nINJECT=1"]), [])
    }

    /// A job demanding the translated capability routes to the pool whose marker it stands for.
    func testDemandsOfTranslatedMarkersMirrorTheMarkerLabel() {
        XCTAssertEqual(
            AzureDevOpsForge.routingLabels(["kinhin", "kinhin_docker -equals true", "xcode"]),
            ["kinhin", "kinhin_docker -equals true", "xcode", "kinhin-docker"])
        XCTAssertEqual(AzureDevOpsForge.routingLabels(["kinhin_host"]), ["kinhin_host", "kinhin-host"])
        XCTAssertEqual(AzureDevOpsForge.routingLabels(["kinhin"]), ["kinhin"])
    }

    func testOnlyOperatingSystemsWithAGuestCountAsDemand() {
        XCTAssertTrue(AzureDevOpsForge.guestCanSatisfy(["kinhin", "Agent.OS -equals Darwin"]))
        XCTAssertTrue(AzureDevOpsForge.guestCanSatisfy(["agent.os -equals linux"]))
        XCTAssertTrue(AzureDevOpsForge.guestCanSatisfy(["Agent.OS"]), "existence only")
        XCTAssertFalse(AzureDevOpsForge.guestCanSatisfy(["kinhin", "Agent.OS -equals Windows_NT"]))
    }

    // MARK: - Construction

    func testMakeResolvesThePoolAndRegistersWithThePAT() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"count":1,"value":[{"id":12,"name":"Mac Fleet"}]}"#.utf8), [:]) }
        let forge = try await AzureDevOpsForge.make(
            credentials: AzureDevOpsCredentials(
                token: "pat", scope: "Mac Fleet", instance: "https://dev.azure.com/acme/"),
            labels: [], account: "ado", session: session())
        XCTAssertEqual(forge.pool, pool)
        XCTAssertEqual(forge.account, "ado")
        XCTAssertEqual(forge.registrationURL(), "https://dev.azure.com/acme", "trailing slash trimmed")
        let token = try await forge.mintRegistrationToken()
        XCTAssertEqual(token, "pat")
        XCTAssertEqual(forge.exitSemantics, .deregisters)
    }

    // MARK: - Unified surface

    func testRunnersAndJobsMapToTheUnifiedShape() async throws {
        StubProtocol.handler = { request in
            if request.url?.path.hasSuffix("/agents") == true {
                return (
                    200,
                    Data(
                        #"{"count":2,"value":[{"id":1,"name":"kinhin-1","status":"online","assignedRequest":{"requestId":2}},{"id":2,"name":"kinhin-2","status":"offline"}]}"#
                            .utf8), [:]
                )
            }
            let json = #"""
                {"count":3,"value":[
                  {"requestId":1,"jobName":"Build","demands":["kinhin"],"definition":{"name":"ios-app"}},
                  {"requestId":3,"jobName":"Other","demands":["linux"],"definition":{"name":"server"}},
                  {"requestId":2,"jobName":"Test","assignTime":"2026-09-30T10:00:00Z","demands":["kinhin"],
                   "reservedAgent":{"name":"kinhin-1"},"definition":{"name":"ios-app"}}
                ]}
                """#
            return (200, Data(json.utf8), [:])
        }
        let forge = makeForge()

        let runners = try await forge.runners()
        XCTAssertEqual(
            runners,
            [
                ForgeRunner(id: "1", name: "kinhin-1", busy: true),
                ForgeRunner(id: "2", name: "kinhin-2", busy: false, online: false),
            ])
        let queued = try await forge.queuedJobs()
        XCTAssertEqual(queued.map(\.name), ["Build"], "a job that doesn't demand kinhin is not this fleet's")
        XCTAssertEqual(queued.first?.repository, "ios-app")
        let running = try await forge.runningJobs()
        XCTAssertEqual(running.map(\.runnerName), ["kinhin-1"])
    }

    func testDeletingARunnerDeletesTheAgent() async throws {
        let calls = Locked<[String]>([])
        StubProtocol.handler = { request in
            calls.withLock { $0.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")") }
            return (204, Data(), [:])
        }
        try await makeForge().deleteRunner(id: "7")
        XCTAssertEqual(calls.withLock { $0 }, ["DELETE /acme/_apis/distributedtask/pools/12/agents/7"])
    }

    // MARK: - Demand

    func testReservedAndUnsatisfiableRequestsAreNotDemand() async throws {
        StubProtocol.handler = { _ in
            let json = #"""
                {"count":4,"value":[
                  {"requestId":1,"jobName":"Open","demands":["kinhin"],"definition":{"name":"a"}},
                  {"requestId":2,"jobName":"Reserved","demands":["kinhin"],"reservedAgent":{"name":"kinhin-9"},
                   "definition":{"name":"a"}},
                  {"requestId":3,"jobName":"Windows","demands":["kinhin","Agent.OS -equals Windows_NT"],
                   "definition":{"name":"a"}},
                  {"requestId":4,"jobName":"Docker","demands":["kinhin","kinhin_docker -equals true"],
                   "definition":{"name":"a"}}
                ]}
                """#
            return (200, Data(json.utf8), [:])
        }
        let queued = try await makeForge().queuedJobs()
        XCTAssertEqual(queued.map(\.name), ["Open", "Docker"])
        XCTAssertTrue(queued[1].labels?.contains("kinhin-docker") == true, "the router sees the marker")
    }

    // MARK: - Offline agents

    private static func agents(_ entries: [(Int, String, String)]) -> Data {
        let items = entries.map { #"{"id":\#($0.0),"name":"\#($0.1)","status":"\#($0.2)"}"# }
        return Data(#"{"count":\#(entries.count),"value":[\#(items.joined(separator: ","))]}"#.utf8)
    }

    /// Agents never remove themselves, so a finished one stays "offline" in the pool. The exit watch needs the
    /// runner gone: an agent seen online and then offline past the grace period is reported gone and its record
    /// deleted. One that never came online is still registering, and a brief blip stays visible.
    func testAnAgentSeenOnlineThatStaysOfflineIsReapedAndReportedGone() async throws {
        let clock = Locked(Date(timeIntervalSince1970: 1_000_000))
        let listing = Locked(Self.agents([(1, "kinhin-1", "online"), (2, "kinhin-2", "offline")]))
        let deletes = Locked<[String]>([])
        StubProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
                deletes.withLock { $0.append(request.url?.path ?? "") }
                return (204, Data(), [:])
            }
            return (200, listing.withLock { $0 }, [:])
        }
        let forge = makeForge(offlineGrace: 60, now: { clock.withLock { $0 } })

        var runners = try await forge.runners()
        XCTAssertEqual(runners.map(\.name), ["kinhin-1", "kinhin-2"], "an agent still registering stays")

        listing.withLock { $0 = Self.agents([(1, "kinhin-1", "offline"), (2, "kinhin-2", "offline")]) }
        clock.withLock { $0 = $0.addingTimeInterval(10) }
        runners = try await forge.runners()
        XCTAssertEqual(runners.map(\.name), ["kinhin-1", "kinhin-2"], "a short blip is not gone")
        XCTAssertTrue(deletes.withLock { $0 }.isEmpty)

        clock.withLock { $0 = $0.addingTimeInterval(61) }
        runners = try await forge.runners()
        XCTAssertEqual(runners.map(\.name), ["kinhin-2"], "kinhin-1 was online, then offline past the grace")
        XCTAssertEqual(deletes.withLock { $0 }, ["/acme/_apis/distributedtask/pools/12/agents/1"])

        // Still listed by a server that did not honour the delete: reported gone, not deleted again.
        runners = try await forge.runners()
        XCTAssertEqual(runners.map(\.name), ["kinhin-2"])
        XCTAssertEqual(deletes.withLock { $0 }.count, 1)
    }

    func testAnAgentThatComesBackOnlineIsNeverReaped() async throws {
        let clock = Locked(Date(timeIntervalSince1970: 1_000_000))
        let listing = Locked(Self.agents([(1, "kinhin-1", "online")]))
        StubProtocol.handler = { _ in (200, listing.withLock { $0 }, [:]) }
        let forge = makeForge(offlineGrace: 30, now: { clock.withLock { $0 } })
        _ = try await forge.runners()
        listing.withLock { $0 = Self.agents([(1, "kinhin-1", "offline")]) }
        clock.withLock { $0 = $0.addingTimeInterval(20) }
        _ = try await forge.runners()
        listing.withLock { $0 = Self.agents([(1, "kinhin-1", "online")]) }
        clock.withLock { $0 = $0.addingTimeInterval(20) }
        _ = try await forge.runners()
        listing.withLock { $0 = Self.agents([(1, "kinhin-1", "offline")]) }
        clock.withLock { $0 = $0.addingTimeInterval(20) }
        let runners = try await forge.runners()
        XCTAssertEqual(runners.map(\.name), ["kinhin-1"], "the offline clock restarted when it was seen online")
    }

    /// A finished agent (offline and idle: `run.sh --once` exited) is reaped after the short idle grace, so its
    /// instance is recycled quickly; one still holding a job (a heartbeat blip) keeps the long grace.
    func testAnIdleOfflineAgentIsReapedSoonerThanABusyOne() async throws {
        let clock = Locked(Date(timeIntervalSince1970: 1_000_000))
        func listing(_ status: String) -> Data {
            Data(
                (#"{"count":2,"value":[{"id":1,"name":"kinhin-idle","status":"\#(status)"},"#
                    + #"{"id":2,"name":"kinhin-busy","status":"\#(status)","assignedRequest":{"requestId":7}}]}"#)
                    .utf8)
        }
        let current = Locked(listing("online"))
        let deletes = Locked<[String]>([])
        StubProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
                deletes.withLock { $0.append(request.url?.lastPathComponent ?? "") }
                return (204, Data(), [:])
            }
            return (200, current.withLock { $0 }, [:])
        }
        let forge = makeForge(offlineGrace: 60, idleOfflineGrace: 15, now: { clock.withLock { $0 } })
        _ = try await forge.runners()

        current.withLock { $0 = listing("offline") }
        _ = try await forge.runners()
        clock.withLock { $0 = $0.addingTimeInterval(16) }
        var runners = try await forge.runners()
        XCTAssertEqual(runners.map(\.name), ["kinhin-busy"], "the idle agent finished; the busy one may be a blip")
        XCTAssertEqual(deletes.withLock { $0 }, ["1"])

        clock.withLock { $0 = $0.addingTimeInterval(45) }
        runners = try await forge.runners()
        XCTAssertTrue(runners.isEmpty, "past the long grace the busy agent is gone too")
        XCTAssertEqual(deletes.withLock { $0 }, ["1", "2"])
    }
}
