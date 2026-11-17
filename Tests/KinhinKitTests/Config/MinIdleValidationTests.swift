import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// `MinIdleValidation.issues(for:)`: every `min_idle` rule the loader enforces, reported without throwing, with a
/// stable field per floor, and the same message `ConfigLoader.parse` fails with.
final class MinIdleValidationTests: XCTestCase {
    private func config(_ mutate: (inout KinhinConfig) -> Void = { _ in }) -> KinhinConfig {
        var cfg = makeTestConfig()
        cfg.maxRunners = 6
        cfg.warmPool = 0
        cfg.imageMinIdle = 0
        cfg.images = []
        cfg.container = nil
        cfg.docker = nil
        mutate(&cfg)
        return cfg
    }

    private func fields(_ cfg: KinhinConfig) -> [MinIdleIssue.Field] {
        MinIdleValidation.issues(for: cfg).map(\.field)
    }

    func testAConfigWithinEveryLimitHasNoIssues() {
        let cfg = config {
            $0.imageMinIdle = 1
            $0.images = [.init(name: "linux", baseImage: "ghcr.io/cirruslabs/ubuntu:latest", minIdle: 1)]
            $0.container = .init(image: "c", cpus: 2, memoryGB: 4, minIdle: 1)
            $0.docker = .init(image: "d", maxSlots: 2, minIdle: 2)
        }
        XCTAssertEqual(MinIdleValidation.issues(for: cfg), [])
    }

    func testDefaultImageFloorPlusWarmPoolMustFitMaxRunners() {
        let cfg = config {
            $0.maxRunners = 2
            $0.warmPool = 1
            $0.imageMinIdle = 2
        }
        XCTAssertTrue(fields(cfg).contains(.imageMinIdle))
        XCTAssertEqual(
            MinIdleValidation.issues(for: cfg).first?.message,
            "image_min_idle (2) plus warm_pool (1) must be <= max_runners (2)")
    }

    func testImageFloorAboveMaxRunnersIsReportedOnTheImageFloor() {
        let cfg = config {
            $0.maxRunners = 2
            $0.imageMinIdle = 3
        }
        XCTAssertTrue(fields(cfg).contains(.imageMinIdle))
    }

    func testNamedImageFloorPlusItsWarmPoolMustFitMaxRunners() {
        let cfg = config {
            $0.maxRunners = 3
            $0.images = [.init(name: "xcode", baseImage: "ghcr.io/cirruslabs/ubuntu:latest", warmPool: 2, minIdle: 2)]
        }
        let issue = MinIdleValidation.issues(for: cfg).first
        XCTAssertEqual(issue?.field, .image("xcode"))
        XCTAssertEqual(
            issue?.message, "images: xcode min_idle (2) plus its warm_pool (2) must be <= max_runners (3)")
    }

    func testUnnamedContainerFloorAboveMaxRunners() {
        let cfg = config {
            $0.maxRunners = 2
            $0.container = .init(image: "c", cpus: 2, memoryGB: 4, minIdle: 3)
        }
        XCTAssertEqual(
            MinIdleValidation.issues(for: cfg).first,
            .init(field: .containerMinIdle, message: "container.min_idle (3) must be <= max_runners (2)"))
    }

    func testNamedPoolFloorAboveMaxRunners() {
        let cfg = config {
            $0.maxRunners = 2
            $0.container = .init(image: "c", cpus: 2, memoryGB: 4)
            $0.container?.pools = [.init(name: "big", image: "c", minIdle: 3)]
        }
        XCTAssertEqual(
            MinIdleValidation.issues(for: cfg).first,
            .init(field: .pool("big"), message: "container.pools.big.min_idle (3) must be <= max_runners (2)"))
    }

    func testPoolFloorAboveThePoolsOwnMax() {
        let cfg = config {
            $0.container = .init(image: "c", cpus: 2, memoryGB: 4)
            $0.container?.pools = [.init(name: "big", image: "c", minIdle: 3, max: 2)]
        }
        XCTAssertEqual(
            MinIdleValidation.issues(for: cfg).first,
            .init(
                field: .pool("big"), message: "container.pools.big.min_idle (3) must be <= container.pools.big.max (2)")
        )
    }

    func testDockerFloorAboveMaxRunners() {
        let cfg = config {
            $0.maxRunners = 2
            $0.docker = .init(image: "d", maxSlots: 8, minIdle: 3)
        }
        XCTAssertEqual(
            MinIdleValidation.issues(for: cfg).first,
            .init(field: .dockerMinIdle, message: "docker.min_idle (3) must be <= max_runners (2)"))
    }

    func testDockerFloorAboveMaxSlots() {
        let cfg = config { $0.docker = .init(image: "d", maxSlots: 1, minIdle: 2) }
        XCTAssertEqual(
            MinIdleValidation.issues(for: cfg),
            [.init(field: .dockerMinIdle, message: "docker.min_idle (2) must be <= docker.max_slots (1)")])
    }

    func testAllFloorsTogetherMustFitMaxRunners() {
        let cfg = config {
            $0.maxRunners = 4
            $0.imageMinIdle = 1
            $0.container = .init(image: "c", cpus: 2, memoryGB: 4, minIdle: 2)
            $0.docker = .init(image: "d", maxSlots: 4, minIdle: 2)
        }
        // No single floor is too big: only the total is.
        let issues = MinIdleValidation.issues(for: cfg)
        XCTAssertEqual(issues.map(\.field), [.total])
        XCTAssertEqual(
            issues.first?.message,
            "min_idle across image_min_idle, images:, container: (every pool) and docker: (5) must be <= max_runners (4)"
        )
    }

    func testWithPoolsTheSectionsOwnFloorIsOnlyADefault() {
        let cfg = config {
            $0.maxRunners = 3
            $0.container = .init(image: "c", cpus: 2, memoryGB: 4, minIdle: 3)
            $0.container?.pools = [.init(name: "a", image: "c", minIdle: 1), .init(name: "b", image: "c", minIdle: 1)]
        }
        XCTAssertEqual(MinIdleValidation.issues(for: cfg), [])
    }

    func testMacOSFloorsTogetherMustFitTwoVMs() {
        let cfg = config {
            $0.imageMinIdle = 1
            $0.images = [.init(name: "a", minIdle: 1), .init(name: "b", minIdle: 1)]
        }
        let issues = MinIdleValidation.issues(for: cfg)
        XCTAssertEqual(issues.map(\.field), [.macOS])
        XCTAssertEqual(MinIdleValidation.macOSVMsPerMac, 2)
        XCTAssertEqual(
            issues.first?.message,
            "min_idle on macOS Tart images (image_min_idle and images:) adds up to 3, but a Mac runs at most 2 macOS "
                + "VMs at once, so the fleet could never keep that many idle")
    }

    func testLinuxTartImagesAreNotBoundByTheMacOSLimit() {
        let linux = "ghcr.io/cirruslabs/ubuntu:latest"
        let cfg = config {
            $0.images = (1...3).map { .init(name: "l\($0)", baseImage: linux, minIdle: 1) }
        }
        XCTAssertEqual(MinIdleValidation.issues(for: cfg), [])
    }

    func testAHugeFloorIsAnIssueNotATrap() {
        let cfg = config {
            $0.imageMinIdle = Int.max
            $0.images = [.init(name: "x", minIdle: Int.max)]
        }
        XCTAssertTrue(fields(cfg).contains(.total))
    }

    func testIssuesAreReportedTogether() {
        let cfg = config {
            $0.maxRunners = 1
            $0.imageMinIdle = 2
            $0.docker = .init(image: "d", maxSlots: 1, minIdle: 2)
        }
        let found = fields(cfg)
        XCTAssertTrue(found.contains(.imageMinIdle) && found.contains(.dockerMinIdle) && found.contains(.total))
    }

    // MARK: - Switched-off pools

    func testADisabledPoolIsExemptFromTheFloorLimits() {
        let cfg = config {
            $0.maxRunners = 2
            $0.container = .init(image: "c", cpus: 2, memoryGB: 4)
            $0.container?.pools = [.init(name: "big", image: "c", minIdle: 5, enabled: false)]
            $0.docker = .init(image: "d", maxSlots: 8, minIdle: 5, enabled: false)
        }
        XCTAssertEqual(MinIdleValidation.issues(for: cfg), [], "disabled pools keep settings without limits")
    }

    func testADisabledPoolsFloorDoesNotCountTowardTheTotal() {
        let cfg = config {
            $0.maxRunners = 3
            $0.container = .init(image: "c", cpus: 2, memoryGB: 4)
            $0.container?.pools = [
                .init(name: "a", image: "c", minIdle: 2), .init(name: "b", image: "c", minIdle: 2, enabled: false),
            ]
        }
        XCTAssertEqual(MinIdleValidation.issues(for: cfg), [])
    }

    func testASwitchedOffTartIsExemptFromTheTartFloors() {
        let cfg = config {
            $0.maxRunners = 2
            $0.imageMinIdle = 5
            $0.images = [.init(name: "a", minIdle: 5)]
            $0.runtimes = .init(defaultRuntime: .appleContainer, tartEnabled: false)
        }
        XCTAssertEqual(MinIdleValidation.issues(for: cfg), [])
    }

    func testAPoolsFloorAboveItsMaxIsStillReportedWhenDisabled() {
        let cfg = config {
            $0.container = .init(image: "c", cpus: 2, memoryGB: 4)
            $0.container?.pools = [.init(name: "big", image: "c", minIdle: 3, max: 2, enabled: false)]
        }
        XCTAssertEqual(fields(cfg), [.pool("big")], "the loader checks max against min_idle for every pool")
    }

    // MARK: - The loader reports the same thing

    func testTheLoaderFailsWithTheFirstIssuesMessage() throws {
        let yaml = """
            accounts:
              - name: github
                forge: github
                scope: "acme"
            max_runners: 2
            image_min_idle: 3
            """
        var expected = try ConfigLoader.parse("accounts:\n  - name: github\n    forge: github\n    scope: \"acme\"\n")
        expected.maxRunners = 2
        expected.imageMinIdle = 3
        let message = try XCTUnwrap(MinIdleValidation.issues(for: expected).first?.message)
        XCTAssertThrowsError(try ConfigLoader.parse(yaml)) { error in
            XCTAssertEqual((error as? ConfigError).map { "\($0)" }?.contains(message), true, "\(error)")
        }
    }
}
