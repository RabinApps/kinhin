import XCTest

@testable import KinhinKit

final class ErrorCategoryTests: XCTestCase {
    func testCategories() {
        XCTAssertEqual(ErrorCategory(ConfigError.missing("repo")), .config)
        XCTAssertEqual(ErrorCategory(ConfigEditError.notFound("/x")), .config)
        XCTAssertEqual(ErrorCategory(GitHubError.forbidden("no")), .auth)
        XCTAssertEqual(ErrorCategory(GiteaError.notFound("x")), .auth)
        XCTAssertEqual(ErrorCategory(TartError.missingBinary(path: "/t")), .runtime)
        XCTAssertEqual(ErrorCategory(EngineError.registrationFailed(vm: "vm", stderr: "x")), .runtime)
        XCTAssertEqual(ErrorCategory(RPCError.timeout), .runtime)
        XCTAssertEqual(ErrorCategory(CancellationError()), .other)
    }
}
