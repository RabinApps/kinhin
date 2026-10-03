import XCTest

@testable import KinhinKit

/// The retry rule every forge client shares: network blips and 0/429/5xx
/// retry, cancellation never does (it must end the caller's task).
final class ForgeHTTPTests: XCTestCase {
    func testCancellationIsNeverTransient() {
        XCTAssertFalse(ForgeHTTP.isTransientNetworkError(URLError(.cancelled)))
        XCTAssertFalse(ForgeTransport.isTransient(URLError(.cancelled)))
        XCTAssertFalse(ForgeTransport.isTransient(CancellationError()))
    }

    func testNetworkBlipsAndServerErrorsAreTransient() {
        XCTAssertTrue(ForgeHTTP.isTransientNetworkError(URLError(.timedOut)))
        XCTAssertTrue(ForgeTransport.isTransient(URLError(.timedOut)))
        XCTAssertTrue(ForgeTransport.isTransient(ForgeAPIError.http(forge: .gitea, code: 503, body: "")))
        XCTAssertTrue(ForgeTransport.isTransient(ForgeAPIError.http(forge: .gitlab, code: 429, body: "")))
        XCTAssertTrue(ForgeTransport.isTransient(ForgeAPIError.nonHTTPResponse(forge: .gitea)))
        XCTAssertFalse(ForgeTransport.isTransient(ForgeAPIError.http(forge: .gitea, code: 404, body: "")))
    }
}
