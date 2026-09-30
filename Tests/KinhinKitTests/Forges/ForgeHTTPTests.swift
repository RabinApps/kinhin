import XCTest

@testable import KinhinKit

/// The retry rule every forge client shares: network blips and 0/429/5xx
/// retry, cancellation never does (it must end the caller's task).
final class ForgeHTTPTests: XCTestCase {
    func testCancellationIsNeverTransient() {
        XCTAssertFalse(ForgeHTTP.isTransientNetworkError(URLError(.cancelled)))
        XCTAssertFalse(GiteaClient.isTransient(URLError(.cancelled)))
        XCTAssertFalse(GitLabClient.isTransient(CancellationError()))
    }

    func testNetworkBlipsAndServerErrorsAreTransient() {
        XCTAssertTrue(ForgeHTTP.isTransientNetworkError(URLError(.timedOut)))
        XCTAssertTrue(GiteaClient.isTransient(GiteaError.http(503, "")))
        XCTAssertTrue(GitLabClient.isTransient(GitLabError.http(429, "")))
        XCTAssertFalse(GiteaClient.isTransient(GiteaError.http(404, "")))
    }
}
