import XCTest

@testable import KinhinKit

/// `tart_home:`, `container_app_root:`, `registry_cache_path:` and `toolchain_cache_path:`: absolute, distinct,
/// non-nested directories, all optional.
final class StorageConfigTests: XCTestCase {
    private static let account = """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        """

    private func parse(_ storage: String) throws -> KinhinConfig {
        try ConfigLoader.parse("\(Self.account)\n\(storage)\n")
    }

    private func invalidMessage(_ storage: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try parse(storage)
            XCTFail("expected a ConfigError", file: file, line: line)
            return ""
        } catch ConfigError.invalid(let why) {
            return why
        } catch {
            XCTFail("expected ConfigError.invalid, got \(error)", file: file, line: line)
            return ""
        }
    }

    func testEveryKeyIsOptionalAndDefaultsToNoOverride() throws {
        let cfg = try parse("")
        XCTAssertEqual(cfg.storage, KinhinConfig.StorageConfig())
        XCTAssertTrue(cfg.storage.isEmpty)
    }

    func testTheFourPathsParseAndLoseATrailingSlash() throws {
        let cfg = try parse(
            """
            tart_home: /Volumes/Storage/tart/
            container_app_root: /Volumes/Storage/container
            registry_cache_path: /Volumes/Storage/kinhin/registry-cache
            toolchain_cache_path: /Volumes/Storage/kinhin/toolchain-cache
            """)
        XCTAssertEqual(cfg.storage.tartHome, "/Volumes/Storage/tart")
        XCTAssertEqual(cfg.storage.containerAppRoot, "/Volumes/Storage/container")
        XCTAssertEqual(cfg.storage.registryCachePath, "/Volumes/Storage/kinhin/registry-cache")
        XCTAssertEqual(cfg.storage.toolchainCachePath, "/Volumes/Storage/kinhin/toolchain-cache")
        XCTAssertEqual(cfg.storage.configured.map(\.location), StorageLocation.allCases)
    }

    func testTheKeysAreKnownToTheSchema() throws {
        let yaml = "tart_home: /a/b\ncontainer_app_root: /a/c\nregistry_cache_path: /a/d\ntoolchain_cache_path: /a/e\n"
        XCTAssertEqual(try ConfigSchema.unknownKeys(in: yaml), [])
    }

    func testAnEmptyPathIsRejected() {
        XCTAssertTrue(invalidMessage("tart_home: \"\"").contains("tart_home must not be empty"))
        XCTAssertTrue(invalidMessage("toolchain_cache_path: \"  \"").contains("toolchain_cache_path must not be empty"))
    }

    func testRelativeAndTildePathsAreRejected() {
        XCTAssertTrue(invalidMessage("tart_home: tart").contains("tart_home must be an absolute path"))
        XCTAssertTrue(invalidMessage("container_app_root: ~/container").contains("write the home folder out"))
        XCTAssertTrue(
            invalidMessage("registry_cache_path: /Volumes/Storage/../cache").contains("must not contain '.' or '..'"))
    }

    func testTheRootAndABareVolumeAreRejected() {
        XCTAssertTrue(invalidMessage("tart_home: /").contains("must not be the root directory"))
        XCTAssertTrue(invalidMessage("container_app_root: /Volumes/Storage").contains("not the volume itself"))
    }

    func testTwoKeysCannotShareOrNestADirectory() {
        let same = invalidMessage("tart_home: /Volumes/S/x\ncontainer_app_root: /Volumes/S/x/")
        XCTAssertTrue(same.contains("tart_home and container_app_root are the same directory"), same)
        let nested = invalidMessage("container_app_root: /Volumes/S/c\nregistry_cache_path: /Volumes/S/c/registry")
        XCTAssertTrue(
            nested.contains("registry_cache_path (/Volumes/S/c/registry) is inside container_app_root"), nested)
        XCTAssertTrue(nested.contains("sibling directory under /Volumes/S/"), nested)
    }

    func testSiblingsWithACommonPrefixAreNotNested() throws {
        let cfg = try parse("tart_home: /Volumes/S/tart\ntoolchain_cache_path: /Volumes/S/tart-cache")
        XCTAssertEqual(cfg.storage.configured.count, 2)
    }

    func testTheTemplateStillParsesWithTheStorageKeysCommentedOut() throws {
        XCTAssertTrue(ConfigLoader.template().contains("# tart_home: /Volumes/Storage/tart"))
        XCTAssertTrue(try ConfigLoader.parse(ConfigLoader.template()).storage.isEmpty)
    }
}
