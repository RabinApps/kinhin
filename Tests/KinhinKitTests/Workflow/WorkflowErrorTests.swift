import XCTest

@testable import KinhinKit

final class WorkflowErrorTests: XCTestCase {
    func testWorkflowErrorsAreConfigurationErrors() {
        let error = WorkflowError.invalidYAML(URL(fileURLWithPath: "/repo/ci.yml"), "unexpected token")
        XCTAssertEqual(ErrorCategory(error), .config)
        XCTAssertTrue(error.localizedDescription.contains("ci.yml"))
        XCTAssertTrue(error.localizedDescription.contains("unexpected token"))
    }
}
