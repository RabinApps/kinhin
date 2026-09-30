import XCTest

@testable import KinhinKit

/// `forge: buildkite` entries in `accounts:`.
final class BuildkiteAccountConfigTests: XCTestCase {
    private func parse(_ account: String) throws -> KinhinConfig {
        try ConfigLoader.parse(
            """
            labels: [macos]
            accounts:
            \(account)
            """)
    }

    func testOrgAndClusterWithDefaultLabels() throws {
        let cfg = try parse(
            """
              - name: ci
                forge: buildkite
                scope: acme/Mac Fleet
            """)
        let account = try XCTUnwrap(cfg.accounts.first)
        XCTAssertEqual(account.forge, .buildkite)
        XCTAssertEqual(account.scope, "acme/Mac Fleet", "cluster names may contain spaces")
        XCTAssertNil(account.instance)
        XCTAssertNil(account.labels, "absent → queue=kinhin")
    }

    func testAgentTagLabels() throws {
        let cfg = try parse(
            """
              - name: ci
                forge: buildkite
                scope: acme/default
                labels: [queue=macos, arch=arm64]
            """)
        XCTAssertEqual(cfg.accounts.first?.labels, ["queue=macos", "arch=arm64"])
    }

    func testRejectsInstanceBareLabelsAndScopeWithoutCluster() {
        let cases: [(String, String)] = [
            ("scope: acme/default\n    instance: https://buildkite.example.com", "hosted only"),
            ("scope: acme/default\n    labels: [macos]", "key=value"),
            ("scope: acme/default\n    labels: []", "key=value"),
            ("scope: acme", "org-slug/cluster"),
        ]
        for (fields, message) in cases {
            XCTAssertThrowsError(
                try parse(
                    """
                      - name: ci
                        forge: buildkite
                        \(fields)
                    """), fields
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains(message), "\(fields): \(error.localizedDescription)")
            }
        }
    }
}
