import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// With one scale set per pool/image, the set a job arrives on decides where
/// it runs, and a spawned runner registers in the set its labels belong to.
final class ScaleSetTargetsTests: XCTestCase {
    private func listener() -> GitHubScaleSetListener {
        GitHubScaleSetListener(
            client: NoopScaleSetClient(), scaleSetIdSupplier: { 1 }, ownerName: "acme", fallbackRepository: "acme/w",
            pollInterval: .seconds(99))
    }

    private func forge(_ targets: [ScaleSetTarget]) -> GitHubScaleSetForge {
        GitHubScaleSetForge(
            account: AccountConfig(name: "s", forge: .github, scope: "acme", scaleSet: .init(name: "kinhin")),
            token: "t", client: FakeGitHub(), labels: [], targets: targets)
    }

    private func targets() -> [ScaleSetTarget] {
        [
            ScaleSetTarget(
                setName: "kinhin", runtime: .tart, routingLabels: ["self-hosted", "arm64"], listener: listener()),
            ScaleSetTarget(
                setName: "kinhin-container", runtime: .appleContainer,
                routingLabels: ["self-hosted", "arm64", "kinhin-container"], listener: listener()),
            ScaleSetTarget(
                setName: "kinhin-xcode", runtime: .tart,
                routingLabels: ["self-hosted", "arm64", "xcode"], listener: listener()),
        ]
    }

    func testRunnerRegistersInTheMostSpecificSetItsLabelsCover() {
        let forge = forge(targets())
        XCTAssertEqual(forge.target(forRunnerLabels: ["self-hosted", "arm64"]).setName, "kinhin")
        XCTAssertEqual(
            forge.target(forRunnerLabels: ["self-hosted", "arm64", "kinhin-container"]).setName, "kinhin-container")
        XCTAssertEqual(
            forge.target(forRunnerLabels: ["Self-Hosted", "ARM64", "xcode"]).setName, "kinhin-xcode",
            "an image VM carries the pool's labels plus the image's; matching ignores case")
    }

    func testJobsAreStampedWithTheirSetsPoolAndLabels() async throws {
        let all = targets()
        let event = GitHubScaleSetJobEvent(
            ownerName: "acme", repositoryName: "w", jobDisplayName: "build", requestLabels: ["kinhin-container"],
            runnerRequestId: "1", eventType: .jobAssigned)
        await all[1].listener.updateSnapshot(
            statistics: .init(totalAssignedJobs: 1, activeNodesCount: 0), pendingActions: ["m": event])
        let jobs = try await forge(all).queuedJobs()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].runtimeHint, .appleContainer)
        XCTAssertEqual(jobs[0].labels, ["self-hosted", "arm64", "kinhin-container"])
    }

    func testRuntimeHintOverridesRoutesAndDefaults() {
        let model = RuntimeConfigModel(
            config: .init(defaultRuntime: "appleContainer", budget: [:], routes: []),
            fleetLabels: ["self-hosted", "arm64"], containerLabels: nil, containerConfigured: true)
        let job = ForgeJob(name: "ci / test", runnerName: nil, repository: "acme/w", labels: [], runtimeHint: .tart)
        XCTAssertEqual(model.runtime(for: job), .tart, "the set the workflow named wins over the default pool")
        let plain = ForgeJob(name: "ci / test", runnerName: nil, repository: "acme/w", labels: [])
        XCTAssertEqual(model.runtime(for: plain), .appleContainer)
    }
}

private actor NoopScaleSetClient: GitHubScaleSetServing {
    func exchangeRegistrationToken(registrationToken: String) async throws -> GitHubScaleSetRegistrationToken {
        GitHubScaleSetRegistrationToken(
            token: "j", expiresAt: .now + 3600, actionsUrl: URL(string: "https://a.invalid")!)
    }
    func ensureScaleSet(name: String, labels: [String], runnerGroup: String?) async throws -> GitHubScaleSet {
        GitHubScaleSet(id: 1, name: name, runnerGroupName: "default", labels: labels)
    }
    func patchScaleSet(id: Int, labels: [String]) async throws {}
    func createSession(scaleSetId: Int, ownerName: String) async throws -> GitHubScaleSetSession { fatalError() }
    func refreshSession(scaleSetId: Int, sessionId: String) async throws -> GitHubScaleSetSession { fatalError() }
    func deleteSession(scaleSetId: Int, sessionId: String) async throws {}
    func pollMessages(session: GitHubScaleSetSession, lastMessageId: String?, maxCapacity: Int) async throws
        -> [GitHubScaleSetMessage]
    { [] }
    func ackMessage(session: GitHubScaleSetSession, messageId: String) async throws {}
    func generateJitConfig(scaleSetId: Int, name: String, workFolder: String) async throws -> GitHubScaleSetJitConfig {
        GitHubScaleSetJitConfig(encodedJitConfig: "jit")
    }
    func scaleSetStatistics(scaleSetId: Int) async throws -> GitHubScaleSetStatistics {
        GitHubScaleSetStatistics(totalAssignedJobs: 0, activeNodesCount: 0)
    }
}
