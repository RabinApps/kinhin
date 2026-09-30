import XCTest

@testable import KinhinKit

final class ConfigTests: XCTestCase {
    private static let account = """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        """
    private static let orgAccount = """
        accounts:
          - name: github
            forge: github
            scope: "acme"
        """

    func testMinimalValidConfig() throws {
        let yaml = """
            \(Self.account)
            labels: ["kinhin"]
            """
        let cfg = try ConfigLoader.parse(yaml)
        XCTAssertEqual(cfg.repo, "acme/widgets")
        XCTAssertEqual(cfg.labels, ["kinhin"])
        XCTAssertEqual(cfg.maxRunners, 1)  // default
        XCTAssertEqual(cfg.runnersPerVM, 1)  // default: classic one-runner-per-VM
        XCTAssertEqual(cfg.vm.cpuCount, 4)
    }

    func testBaseImageParsesAndRoundTrips() throws {
        let yaml = """
            \(Self.account)
            labels: ["x"]
            base_image: "ghcr.io/cirruslabs/macos-sequoia-base:latest"
            """
        let cfg = try ConfigLoader.parse(yaml)
        XCTAssertEqual(cfg.baseImage, "ghcr.io/cirruslabs/macos-sequoia-base:latest")
        // A local VM name is valid too (the --linux scratch path).
        XCTAssertEqual(
            try ConfigLoader.parse("\(Self.account)\nlabels: [x]\nbase_image: ubuntu-scratch\n").baseImage,
            "ubuntu-scratch")
        XCTAssertNil(try ConfigLoader.parse("\(Self.account)\nlabels: [x]\n").baseImage, "absent key = default")
    }

    func testBaseImageValidation() {
        XCTAssertThrowsError(try ConfigLoader.parse("\(Self.account)\nlabels: [x]\nbase_image: \"\"\n"))
        XCTAssertThrowsError(try ConfigLoader.parse("\(Self.account)\nlabels: [x]\nbase_image: \"--privileged\"\n"))
        XCTAssertThrowsError(try ConfigLoader.parse("\(Self.account)\nlabels: [x]\nbase_image: \"two words\"\n"))
    }

    func testBaseImageDigestPinsParseAndMalformedOnesAreRejected() throws {
        let digest = String(repeating: "ab", count: 32)
        let pinned = try ConfigLoader.parse(
            "\(Self.account)\nlabels: [x]\nbase_image: \"ghcr.io/cirruslabs/ubuntu:latest@sha256:\(digest)\"\n")
        XCTAssertEqual(pinned.baseImage, "ghcr.io/cirruslabs/ubuntu:latest@sha256:\(digest)")
        // A pin that isn't 64 lowercase hex chars is a typo, not a pin.
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                "\(Self.account)\nlabels: [x]\nbase_image: \"ghcr.io/cirruslabs/ubuntu@sha256:short\"\n"))
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                "\(Self.account)\nlabels: [x]\nbase_image: \"ghcr.io/cirruslabs/ubuntu@sha256:\(String(repeating: "AB", count: 32))\"\n"
            ))
    }

    func testRunnersPerVMParses() throws {
        let yaml = """
            \(Self.account)
            labels: ["x"]
            max_runners: 2
            runners_per_vm: 6
            """
        XCTAssertEqual(try ConfigLoader.parse(yaml).runnersPerVM, 6)
    }

    func testRunnersPerVMRejectsZeroAndNine() throws {
        for bad in [0, 9] {
            let yaml = """
                accounts:
                  - name: github
                    forge: github
                    scope: "a/b"
                labels: ["x"]
                runners_per_vm: \(bad)
                """
            XCTAssertThrowsError(try ConfigLoader.parse(yaml)) { error in
                guard case ConfigError.invalid(let why) = (error as! ConfigError) else {
                    return XCTFail("wrong error")
                }
                XCTAssertTrue(why.contains("runners_per_vm"), "\(bad): \(why)")
            }
        }
    }

    func testFullConfig() throws {
        let yaml = """
            \(Self.account)
            labels: ["a", "b"]
            min_runners: 1
            max_runners: 3
            poll_interval: 15
            vm:
              cpu: 3
              memory_gb: 6
              ephemeral: false
            image: "kinhin-base"
            disk_gb: 40
            reserve:
              cpu: 1
              memory_gb: 2
              disk_gb: 15
            """
        let cfg = try ConfigLoader.parse(yaml)
        XCTAssertEqual(cfg.minRunners, 1)
        XCTAssertEqual(cfg.maxRunners, 3)
        XCTAssertEqual(cfg.vm.cpuCount, 3)
        XCTAssertEqual(cfg.vm.memoryGB, 6)
        XCTAssertFalse(cfg.vm.ephemeral)
        XCTAssertEqual(cfg.image, "kinhin-base")
        XCTAssertEqual(cfg.diskGB, 40)
        XCTAssertEqual(cfg.reserve.cpu, 1)
        XCTAssertEqual(cfg.reserve.diskGB, 15)
    }

    func testReserveDiskDefaultsToTen() throws {
        let cfg = try ConfigLoader.parse("\(Self.account)\nlabels: [x]\n")
        XCTAssertEqual(cfg.reserve.diskGB, 10, "the default reserve keeps disk headroom too")
    }

    func testNegativeReserveDiskThrows() {
        XCTAssertThrowsError(
            try ConfigLoader.parse("\(Self.account)\nlabels: [x]\nreserve:\n  disk_gb: -1\n")
        ) { error in
            guard case .invalid(let message) = error as? ConfigError else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(message.contains("reserve.disk_gb"), "\(message)")
        }
    }

    func testMissingAccountsIsTheTemplateState() throws {
        // No accounts is valid: it is the starter-template state (the
        // checklist classifies it; the engine refuses to run).
        let cfg = try ConfigLoader.parse("labels: [\"x\"]")
        XCTAssertTrue(cfg.accounts.isEmpty)
    }

    func testBadScopeShapeThrows() {
        // Three segments is neither owner/name nor an org.
        XCTAssertThrowsError(
            try ConfigLoader.parse("accounts:\n  - name: github\n    forge: github\n    scope: \"a/b/c\"\n")
        ) { error in
            guard case ConfigError.invalid(let why) = (error as! ConfigError) else {
                return XCTFail("wrong error")
            }
            XCTAssertTrue(why.contains("scope must be"), why)
        }
        XCTAssertThrowsError(
            try ConfigLoader.parse("accounts:\n  - name: github\n    forge: github\n    scope: \"acme//widgets\"\n")
        ) { _ in
            // empty segment
        }
    }

    // MARK: org scope (many repos, one fleet)

    func testOrgScopeParses() throws {
        let cfg = try ConfigLoader.parse(Self.orgAccount)
        XCTAssertEqual(cfg.repo, "acme")
        XCTAssertFalse(cfg.repo.contains("/"))
    }

    func testOrgScopeCredentialsRouteToOrgEndpoints() {
        let creds = GitHubCredentials(token: "t", scope: "acme")
        XCTAssertTrue(creds.isOrgScope)
        XCTAssertEqual(creds.configureURL, "https://github.com/organizations/acme")
        XCTAssertEqual(creds.owner, "acme")
    }

    func testRepoScopeCredentialsKeepLegacyURLs() {
        let creds = GitHubCredentials(token: "t", scope: "acme/widgets")
        XCTAssertFalse(creds.isOrgScope)
        XCTAssertEqual(creds.configureURL, "https://github.com/acme/widgets")
    }

    func testMaxBelowMinThrows() {
        let yaml = """
            \(Self.account)
            labels: ["x"]
            min_runners: 3
            max_runners: 2
            """
        XCTAssertThrowsError(try ConfigLoader.parse(yaml)) { error in
            guard case ConfigError.invalid(let why) = (error as! ConfigError) else {
                return XCTFail("wrong error")
            }
            XCTAssertTrue(why.contains("max_runners"))
        }
    }

    func testTinyPollIntervalThrows() {
        let yaml = """
            \(Self.account)
            labels: ["x"]
            poll_interval: 1
            """
        XCTAssertThrowsError(try ConfigLoader.parse(yaml))
    }

    func testTemplateContainsKeyFields() {
        // The shipped template must document every knob a user may set.
        let template = ConfigLoader.template()
        for key in [
            "accounts:", "labels:", "min_runners:", "max_runners:", "runners_per_vm:", "poll_interval:", "vm:",
            "image:",
            "reserve:",
        ] {
            XCTAssertTrue(template.contains(key), "template missing '\(key)'")
        }
    }
}
