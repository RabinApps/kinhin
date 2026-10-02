import XCTest

@testable import KinhinKit

final class WorkflowProbeTests: XCTestCase {
    private func hits(_ workflow: String) throws -> [ToolchainHit] {
        let fixture = try ProjectFixture([".github/workflows/ci.yml": workflow])
        return try WorkflowProbe().hits(in: fixture.reader)
    }

    func testSetupActionsAndVersions() throws {
        let found = try hits(
            """
            on: push
            jobs:
              build:
                runs-on: ubuntu-latest
                steps:
                  - uses: actions/setup-node@v4
                    with:
                      node-version: 20
                  - uses: actions/setup-python@v5
                    with:
                      python-version: "3.10"
                  - uses: dtolnay/rust-toolchain@stable
                  - uses: actions/setup-go@v5
                    with:
                      go-version: ${{ matrix.go }}
            """)
        XCTAssertEqual(found.first { $0.id == "node" }?.version, "20")
        XCTAssertEqual(found.first { $0.id == "python" }?.version, "3.10")
        XCTAssertEqual(found.first { $0.id == "rust" }?.version, "stable")
        XCTAssertNil(found.first { $0.id == "go" }?.version)
        XCTAssertTrue(found.allSatisfy { $0.precedence == .workflow })
    }

    func testRunLinesMatchOnlyAtCommandPosition() throws {
        let found = try hits(
            """
            jobs:
              j:
                steps:
                  - run: |
                      cd terraform
                      # kubectl apply
                      terraform plan && npx playwright test
                      echo done
            """)
        XCTAssertEqual(Set(found.map(\.id)), ["terraform", "playwright"])
    }

    func testInvalidWorkflowIsSkipped() throws {
        XCTAssertTrue(try hits("jobs: [unclosed").isEmpty)
    }
}
