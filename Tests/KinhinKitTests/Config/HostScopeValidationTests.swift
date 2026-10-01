import XCTest

@testable import KinhinKit

/// The host runner registers at the account's scope, so a host route is only
/// safe when every account is scoped to a single repository.
final class HostScopeValidationTests: XCTestCase {
    private func yaml(forge: String = "github", scope: String, host: Bool = true) -> String {
        """
        accounts:
          - name: main
            forge: \(forge)
            scope: "\(scope)"
        labels: [x]
        """
            + (host
                ? """

                runtimes:
                  routes:
                    - pattern: "acme/scripts"
                      runtime: host
                      consent: true
                """ : "")
    }

    func testOrgScopedAccountIsRefusedWithAHostRoute() {
        XCTAssertThrowsError(try ConfigLoader.parse(yaml(scope: "acme"))) { error in
            guard case .invalid(let message) = error as? ConfigError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("single-repository"), message)
            XCTAssertTrue(message.contains("'main'"), message)
        }
    }

    func testClusterAndPoolScopesAreRefusedWithAHostRoute() {
        XCTAssertThrowsError(try ConfigLoader.parse(yaml(forge: "buildkite", scope: "acme/ci")))
        XCTAssertThrowsError(try ConfigLoader.parse(yaml(forge: "azuredevops", scope: "Default")))
    }

    func testRepoScopedAccountIsAllowedWithAHostRoute() throws {
        XCTAssertTrue(try ConfigLoader.parse(yaml(scope: "acme/scripts")).hostRoutesConfigured)
    }

    func testOrgScopeStillWorksWithoutAHostRoute() throws {
        XCTAssertFalse(try ConfigLoader.parse(yaml(scope: "acme", host: false)).hostRoutesConfigured)
    }
}

/// Values that end up as positional arguments or API path segments.
final class ConfigValueSafetyTests: XCTestCase {
    func testScopesCannotReshapeAPIPaths() {
        for scope in ["acme/re?po", "acme/re#po", "acme/re%2Fpo", "acme/..", "../x", "acme/a b"] {
            XCTAssertFalse(AccountConfig.isValidScope(scope), scope)
        }
        XCTAssertTrue(AccountConfig.isValidScope("acme/widgets.v2_x-y"))
        XCTAssertTrue(AccountConfig.isValidScope("acme"))
    }

    func testImageReferencesCannotBecomeFlags() {
        XCTAssertThrowsError(try ConfigLoader.requireSafeImageReference("--privileged", key: "docker.image"))
        XCTAssertThrowsError(try ConfigLoader.requireSafeImageReference("img --rm", key: "docker.image"))
        XCTAssertThrowsError(try ConfigLoader.requireSafeImageReference("img\n", key: "docker.image"))
        XCTAssertNoThrow(try ConfigLoader.requireSafeImageReference("ghcr.io/acme/ci:1.2@sha256:abc", key: "x"))
    }

    func testRunnerVersionTagWithTrailingNewlineIsRefused() {
        let payload = Data(#"{"tag_name":"v1.2.3\n"}"#.utf8)
        XCTAssertThrowsError(try RunnerVersionResolver.stableTag(from: payload, feed: "f", fallback: "1.0.0"))
        let clean = Data(#"{"tag_name":"v1.2.3"}"#.utf8)
        XCTAssertEqual(try RunnerVersionResolver.stableTag(from: clean, feed: "f", fallback: "1.0.0"), "1.2.3")
    }
}
