import XCTest

@testable import KinhinKit

/// Applying the config's storage settings moves the toolchain cache and the Docker Hub cache, and exports
/// `TART_HOME` for every `tart` the process starts; dropping them hands everything back.
final class StorageLocationsTests: XCTestCase {
    override func tearDown() {
        StorageLocations.apply(KinhinConfig.StorageConfig())
        super.tearDown()
    }

    func testApplyMovesTheCachesAndExportsTartHome() {
        let inherited = ProcessInfo.processInfo.environment["TART_HOME"]
        StorageLocations.apply(
            KinhinConfig.StorageConfig(
                tartHome: "/Volumes/S/tart", registryCachePath: "/Volumes/S/registry",
                toolchainCachePath: "/Volumes/S/toolchains"))
        XCTAssertEqual(ProcessInfo.processInfo.environment["TART_HOME"], "/Volumes/S/tart")
        XCTAssertEqual(Paths.toolchainCache.path, "/Volumes/S/toolchains")
        XCTAssertEqual(DockerRegistryCache.defaultDataDirectory.path, "/Volumes/S/registry")
        XCTAssertEqual(TartController.diskImage(for: "vm"), "/Volumes/S/tart/vms/vm/disk.img")

        StorageLocations.apply(KinhinConfig.StorageConfig())
        XCTAssertEqual(ProcessInfo.processInfo.environment["TART_HOME"], inherited, "the inherited value is back")
        XCTAssertEqual(Paths.toolchainCache, Paths.defaultToolchainCache)
        XCTAssertEqual(DockerRegistryCache.defaultDataDirectory.lastPathComponent, "registry-cache")
    }

    func testApplyMarksTheStorageAsKnown() {
        StorageLocations.apply(KinhinConfig.StorageConfig(toolchainCachePath: "/Volumes/S/toolchains"))
        XCTAssertTrue(StorageLocations.isApplied, "ensureSupportDirectories may create the toolchain cache from now on")
    }

    func testAConfigWithoutTartHomeLeavesAnInheritedTartHomeAlone() {
        let inherited = ProcessInfo.processInfo.environment["TART_HOME"]
        StorageLocations.apply(KinhinConfig.StorageConfig(toolchainCachePath: "/Volumes/S/toolchains"))
        XCTAssertEqual(ProcessInfo.processInfo.environment["TART_HOME"], inherited)
    }

    func testOnlyTheMacsOwnConfigIsApplied() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.yaml")
        let yaml = [
            "accounts:",
            "  - name: github",
            "    forge: github",
            "    scope: \"acme/widgets\"",
            "toolchain_cache_path: /Volumes/S/toolchains",
        ].joined(separator: "\n")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        let cfg = try ConfigLoader.load(from: file)
        XCTAssertEqual(cfg.storage.toolchainCachePath, "/Volumes/S/toolchains")
        XCTAssertNil(StorageLocations.current.toolchainCachePath, "an imported or validated file changes nothing")
    }
}
