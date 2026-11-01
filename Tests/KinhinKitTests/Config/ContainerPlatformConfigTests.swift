import XCTest

@testable import KinhinKit

/// `container.platform` and a pool's `platform` (#75, step 3): parsed and inherited like the other keys, and the
/// cross-pool rules that keep jobs and bakes unambiguous.
final class ContainerPlatformConfigTests: XCTestCase {
    private static let head = """
        accounts:
          - name: github
            forge: github
            scope: "acme"
        labels: [self-hosted, arm64]
        max_runners: 10

        """

    private func parse(_ container: String) throws -> KinhinConfig {
        try ConfigLoader.parse(Self.head + container)
    }

    private func invalidMessage(_ container: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try parse(container)
            XCTFail("expected a ConfigError for:\n\(container)", file: file, line: line)
            return ""
        } catch ConfigError.invalid(let why) {
            return why
        } catch {
            XCTFail("expected ConfigError.invalid, got \(error)", file: file, line: line)
            return ""
        }
    }

    func testArm64IsTheDefault() throws {
        let cfg = try parse("container:\n  image: kinhin-ci-linux\n")
        XCTAssertEqual(cfg.container?.platform, .arm64)
        XCTAssertEqual(cfg.container?.effectivePools.map(\.platform), [.arm64])
    }

    func testTheSectionCanRunAmd64() throws {
        let cfg = try parse("container:\n  image: kinhin-ci-linux-x64\n  platform: linux/amd64\n")
        XCTAssertEqual(cfg.container?.platform, .amd64)
        XCTAssertEqual(cfg.container?.defaultPool.platform, .amd64, "the section's one pool runs it")
    }

    func testPoolsInheritThePlatformAndMayOverrideIt() throws {
        let cfg = try parse(
            """
            container:
              platform: amd64
              pools:
                x64: { image: kinhin-ci-linux-x64, labels: [linux] }
                linux: { image: kinhin-ci-linux, labels: [linux], platform: linux/arm64 }

            """)
        let pools = try XCTUnwrap(cfg.container?.pools)
        XCTAssertEqual(pools.map(\.name), ["linux", "x64"])
        XCTAssertEqual(pools.map(\.platform), [.arm64, .amd64])
        XCTAssertEqual(cfg.container?.platform(forImage: "kinhin-ci-linux-x64"), .amd64)
        XCTAssertEqual(cfg.container?.platform(forImage: "kinhin-ci-linux"), .arm64)
    }

    func testPoolsWithTheSameLabelsAreFineOnDifferentPlatforms() throws {
        let cfg = try parse(
            """
            container:
              pools:
                linux: { image: kinhin-ci-linux, labels: [linux] }
                linux-x64: { image: kinhin-ci-linux-x64, labels: [linux], platform: linux/amd64 }

            """)
        XCTAssertEqual(cfg.container?.pools.count, 2, "the architecture label tells them apart")
    }

    func testTheLoaderRejects() {
        XCTAssertTrue(
            invalidMessage("container:\n  image: i\n  platform: linux/riscv64\n").contains(
                "container.platform must be linux/arm64 or linux/amd64, got \"linux/riscv64\""))
        XCTAssertTrue(
            invalidMessage(
                """
                container:
                  pools:
                    a: { image: i, labels: [linux] }
                    b: { image: i, labels: [linux, big], platform: linux/amd64 }

                """
            ).contains("container.pools a and b both run image i but for different platforms"))
        XCTAssertTrue(
            invalidMessage(
                """
                container:
                  pools:
                    a: { image: i, labels: [linux], platform: linux/amd64 }
                    b: { image: j, labels: [linux], platform: amd64 }

                """
            ).contains("have the same labels and platform"))
    }

    func testFlagsStillCannotPickThePlatform() {
        for flags in ["[\"--platform\", \"linux/amd64\"]", "[\"--arch\", \"amd64\"]", "[\"-a\", \"amd64\"]"] {
            let why = invalidMessage("container:\n  image: i\n  flags: \(flags)\n")
            XCTAssertTrue(why.contains("container.flags must not set"), why)
            XCTAssertTrue(why.contains("from platform"), why)
        }
    }
}
