import XCTest

@testable import KinhinKit

/// `forge: azuredevops` entries in `accounts:`.
final class AzureDevOpsAccountConfigTests: XCTestCase {
    private func parse(_ account: String) throws -> KinhinConfig {
        try ConfigLoader.parse(
            """
            labels: [macos]
            accounts:
            \(account)
            """)
    }

    func testOrganizationURLAndPool() throws {
        let cfg = try parse(
            """
              - name: ado
                forge: azuredevops
                instance: https://dev.azure.com/acme
                scope: Mac Fleet
            """)
        let account = try XCTUnwrap(cfg.accounts.first)
        XCTAssertEqual(account.forge, .azuredevops)
        XCTAssertEqual(account.scope, "Mac Fleet", "pool names may contain spaces")
        XCTAssertEqual(account.instance, "https://dev.azure.com/acme")
        XCTAssertNil(account.labels, "absent → the pool is kinhin's alone")
    }

    func testCapabilityLabels() throws {
        let cfg = try parse(
            """
              - name: ado
                forge: azuredevops
                instance: https://tfs.example.com/tfs/DefaultCollection
                scope: Default
                labels: [kinhin, xcode=16]
            """)
        XCTAssertEqual(cfg.accounts.first?.labels, ["kinhin", "xcode=16"])
    }

    func testRejectsMissingOrBadInstanceAndLabels() {
        let cases: [(String, String)] = [
            ("scope: Default", "instance is required"),
            ("scope: Default\n    instance: https://dev.azure.com/acme/_apis", "organization URL"),
            ("scope: Default\n    instance: https://dev.azure.com/acme\n    labels: [macos:host]", "capabilities"),
        ]
        for (fields, message) in cases {
            XCTAssertThrowsError(
                try parse(
                    """
                      - name: ado
                        forge: azuredevops
                        \(fields)
                    """), fields
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains(message), "\(fields): \(error.localizedDescription)")
            }
        }
    }
}
