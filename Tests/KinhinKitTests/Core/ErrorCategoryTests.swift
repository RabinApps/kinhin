import XCTest

@testable import KinhinKit

final class ErrorCategoryTests: XCTestCase {
    func testCategories() {
        XCTAssertEqual(ErrorCategory(ConfigError.missing("repo")), .config)
        XCTAssertEqual(ErrorCategory(ConfigEditError.notFound("/x")), .config)
        XCTAssertEqual(ErrorCategory(WorkflowError.invalidYAML(URL(fileURLWithPath: "/tmp/ci.yml"), "bad")), .config)
        XCTAssertEqual(ErrorCategory(GitHubError.forbidden("no")), .auth)
        XCTAssertEqual(ErrorCategory(ForgeAPIError.notFound(forge: .gitea, what: "x")), .auth)
        XCTAssertEqual(ErrorCategory(ForgeAPIError.http(forge: .github, code: 503, body: "")), .auth)
        XCTAssertEqual(ErrorCategory(TartError.missingBinary(path: "/t")), .runtime)
        XCTAssertEqual(ErrorCategory(EngineError.registrationFailed(vm: "vm", stderr: "x")), .runtime)
        XCTAssertEqual(ErrorCategory(RPCError.timeout), .runtime)
        XCTAssertEqual(ErrorCategory(CancellationError()), .other)
    }
}
