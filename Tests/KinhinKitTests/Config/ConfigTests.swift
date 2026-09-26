import XCTest

@testable import KinhinKit

final class ConfigTests: XCTestCase {
    func testMinimalValidConfig() throws {
        let yaml = """
            repo: "acme/widgets"
            labels: ["kinhin"]
            """
        let cfg = try ConfigLoader.parse(yaml)
        XCTAssertEqual(cfg.repo, "acme/widgets")
        XCTAssertEqual(cfg.labels, ["kinhin"])
        XCTAssertEqual(cfg.maxRunners, 1)  // default
        XCTAssertEqual(cfg.runnersPerVM, 1)  // default: classic one-runner-per-VM
        XCTAssertEqual(cfg.vm.cpuCount, 4)
    }

    func testRunnersPerVMParses() throws {
        let yaml = """
            repo: "acme/widgets"
            labels: ["x"]
            max_runners: 2
            runners_per_vm: 6
            """
        XCTAssertEqual(try ConfigLoader.parse(yaml).runnersPerVM, 6)
    }

    func testRunnersPerVMRejectsZeroAndNine() throws {
        for bad in [0, 9] {
            let yaml = """
                repo: "a/b"
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
            repo: "acme/widgets"
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
        let cfg = try ConfigLoader.parse("repo: \"acme/widgets\"\nlabels: [x]\n")
        XCTAssertEqual(cfg.reserve.diskGB, 10, "the default reserve keeps disk headroom too")
    }

    func testNegativeReserveDiskThrows() {
        XCTAssertThrowsError(
            try ConfigLoader.parse("repo: \"acme/widgets\"\nlabels: [x]\nreserve:\n  disk_gb: -1\n")
        ) { error in
            guard case .invalid(let message) = error as? ConfigError else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(message.contains("reserve.disk_gb"), "\(message)")
        }
    }

    func testMissingRepoThrows() {
        XCTAssertThrowsError(try ConfigLoader.parse("labels: [\"x\"]")) { error in
            XCTAssertEqual(error as? ConfigError, .missing("repo"))
        }
    }

    func testBadRepoShapeThrows() {
        // Three segments is neither owner/name nor an org.
        XCTAssertThrowsError(try ConfigLoader.parse("repo: \"a/b/c\"")) { error in
            guard case ConfigError.invalid(let why) = (error as! ConfigError) else {
                return XCTFail("wrong error")
            }
            XCTAssertTrue(why.contains("scope must be"), why)
        }
        XCTAssertThrowsError(try ConfigLoader.parse("repo: \"acme//widgets\"")) { _ in
            // empty segment
        }
    }

    // MARK: org scope (many repos, one fleet)

    func testOrgScopeParses() throws {
        let cfg = try ConfigLoader.parse("repo: \"acme\"\nlabels: [\"x\"]")
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
            repo: "a/b"
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
            repo: "a/b"
            labels: ["x"]
            poll_interval: 1
            """
        XCTAssertThrowsError(try ConfigLoader.parse(yaml))
    }

    func testTemplateContainsKeyFields() {
        // The shipped template must document every knob a user may set.
        let template = ConfigLoader.template()
        for key in [
            "repo:", "labels:", "min_runners:", "max_runners:", "runners_per_vm:", "poll_interval:", "vm:", "image:",
            "reserve:",
        ] {
            XCTAssertTrue(template.contains(key), "template missing '\(key)'")
        }
    }
}
