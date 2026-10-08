import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Requeue and skip have nothing to act on for a scale-set account (the
/// listener carries no workflow-run ids), so they must say so, not succeed.
final class ScaleSetQueueActionTests: XCTestCase {
    private func forge() -> GitHubScaleSetForge {
        let listener = GitHubScaleSetListener(
            client: GitHubScaleSetClient(credentials: GitHubCredentials(token: "t", scope: "acme")),
            scaleSetIdSupplier: { 1 }, ownerName: "acme", fallbackRepository: "acme/w",
            pollInterval: .seconds(99))
        return GitHubScaleSetForge(
            account: AccountConfig(name: "s", forge: .github, scope: "acme", scaleSet: .init(name: "kinhin")),
            token: "t", client: FakeGitHub(), listener: listener)
    }

    func testRequeueReportsItIsNotSupported() async {
        do {
            try await forge().userRequeueQueuedJobs()
            XCTFail("a silent success would claim the queue was requeued")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not supported for scale-set accounts"), "\(error)")
        }
    }

    func testSkipReportsItIsNotSupported() async {
        do {
            try await forge().userSkipQueuedJobs()
            XCTFail("a silent success would claim the queue was skipped")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not supported for scale-set accounts"), "\(error)")
        }
    }
}
