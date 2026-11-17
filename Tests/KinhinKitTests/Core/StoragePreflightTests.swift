import XCTest

@testable import KinhinKit

/// The mount/ownership preflight: a configured path must sit on its mounted volume, with ownership enabled, and be a
/// directory (or not exist yet). Volumes are fixtures; one test reads the live `statfs`.
final class StoragePreflightTests: XCTestCase {
    private func preflight(
        mountPoint: String?, ignoresOwnership: Bool = false, entry: StoragePreflight.Entry = .directory
    ) -> StoragePreflight {
        StoragePreflight(
            volume: { _ in
                mountPoint.map { StoragePreflight.Volume(mountPoint: $0, ignoresOwnership: ignoresOwnership) }
            },
            entry: { _ in entry })
    }

    func testAPathOnItsMountedVolumeWithOwnershipIsReady() {
        let check = preflight(mountPoint: "/Volumes/Storage")
        XCTAssertNil(check.problem(.tartHome, path: "/Volumes/Storage/tart"))
    }

    func testAPathThatDoesNotExistYetIsReadyOnAMountedVolume() {
        let check = preflight(mountPoint: "/Volumes/Storage", entry: .missing)
        XCTAssertNil(check.problem(.registryCache, path: "/Volumes/Storage/kinhin/registry-cache"))
    }

    func testAnUnmountedVolumeResolvesToTheBootVolumeAndFails() throws {
        let check = preflight(mountPoint: "/", entry: .missing)
        let problem = try XCTUnwrap(check.problem(.containerAppRoot, path: "/Volumes/Storage/container"))
        XCTAssertEqual(problem.problem, "the volume /Volumes/Storage is not mounted")
        XCTAssertTrue(problem.fix.contains("diskutil mount Storage"), problem.fix)
        XCTAssertTrue(problem.fix.contains("will not use the internal disk"), problem.fix)
        let message = problem.localizedDescription
        XCTAssertTrue(message.hasPrefix("container_app_root (Apple container app root, /Volumes/Storage/container)"))
    }

    func testAStrayFolderOfTheVolumesNameOnTheBootDiskIsNotTheVolume() {
        let check = preflight(mountPoint: "/")
        XCTAssertNotNil(check.problem(.tartHome, path: "/Volumes/Storage/tart"))
    }

    func testAVolumeMountedInsideTheExpectedOneCounts() {
        let inner = StoragePreflight.Volume(mountPoint: "/Volumes/Storage/inner", ignoresOwnership: false)
        let other = StoragePreflight.Volume(mountPoint: "/Volumes/Storage2", ignoresOwnership: false)
        XCTAssertTrue(StoragePreflight.isMounted("/Volumes/Storage", holding: inner))
        XCTAssertFalse(StoragePreflight.isMounted("/Volumes/Storage", holding: other))
    }

    func testIgnoredOwnershipFailsWithTheEnableOwnershipCommand() throws {
        let check = preflight(mountPoint: "/Volumes/Storage", ignoresOwnership: true)
        let tart = try XCTUnwrap(check.problem(.tartHome, path: "/Volumes/Storage/tart"))
        XCTAssertEqual(tart.problem, "ownership is disabled on /Volumes/Storage")
        XCTAssertEqual(tart.fix, "run `sudo diskutil enableOwnership /Volumes/Storage`")
        let container = try XCTUnwrap(check.problem(.containerAppRoot, path: "/Volumes/Storage/container"))
        XCTAssertTrue(container.fix.contains("recopy any container files"), container.fix)
    }

    func testAFileWhereADirectoryBelongsFails() throws {
        let check = preflight(mountPoint: "/Volumes/Storage", entry: .notDirectory)
        let problem = try XCTUnwrap(check.problem(.toolchainCache, path: "/Volumes/Storage/cache"))
        XCTAssertEqual(problem.problem, "/Volumes/Storage/cache exists but is not a directory")
    }

    func testALowercaseVolumesPathIsStillCheckedForItsMount() throws {
        XCTAssertEqual(StoragePreflight.expectedMountPoint(for: "/volumes/Storage/tart"), "/Volumes/Storage")
        let unmounted = preflight(mountPoint: "/", entry: .missing)
        let problem = try XCTUnwrap(unmounted.problem(.tartHome, path: "/volumes/Storage/tart"))
        XCTAssertEqual(problem.problem, "the volume /Volumes/Storage is not mounted")
        let mounted = preflight(mountPoint: "/Volumes/Storage", entry: .missing)
        XCTAssertNil(mounted.problem(.tartHome, path: "/volumes/storage/tart"))
    }

    func testAFileInThePathBlocksAMissingDirectory() throws {
        let check = preflight(mountPoint: "/Volumes/Storage", entry: .blockedByFile("/Volumes/Storage/blocker"))
        let problem = try XCTUnwrap(check.problem(.toolchainCache, path: "/Volumes/Storage/blocker/cache"))
        XCTAssertEqual(
            problem.problem, "/Volumes/Storage/blocker is a file, so /Volumes/Storage/blocker/cache cannot be created")
    }

    func testLiveEntryFindsAFileAmongTheAncestors() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        XCTAssertEqual(
            StoragePreflight.liveEntry(blocker.appendingPathComponent("a/b").path), .blockedByFile(blocker.path))
        XCTAssertEqual(StoragePreflight.liveEntry(root.appendingPathComponent("new/dir").path), .missing)
        XCTAssertEqual(StoragePreflight.liveEntry(root.path), .directory)
        XCTAssertEqual(StoragePreflight.liveEntry(blocker.path), .notDirectory)
    }

    func testAPathOutsideVolumesHasNoMountToWaitFor() {
        let check = preflight(mountPoint: "/", entry: .missing)
        XCTAssertNil(check.problem(.tartHome, path: "/Users/ci/tart"))
        XCTAssertNil(StoragePreflight.expectedMountPoint(for: "/Users/ci/tart"))
        XCTAssertEqual(StoragePreflight.expectedMountPoint(for: "/Volumes/Storage/a/b"), "/Volumes/Storage")
    }

    func testAnUnreadableVolumeFails() throws {
        let problem = try XCTUnwrap(preflight(mountPoint: nil).problem(.tartHome, path: "/Volumes/Storage/tart"))
        XCTAssertEqual(problem.problem, "the volume holding /Volumes/Storage/tart could not be read")
    }

    func testCheckReportsEveryConfiguredPathAndRequireReadyThrowsTheFirstProblem() {
        let storage = KinhinConfig.StorageConfig(
            tartHome: "/Users/ci/tart", registryCachePath: "/Volumes/Gone/registry")
        let check = StoragePreflight(
            volume: { _ in StoragePreflight.Volume(mountPoint: "/", ignoresOwnership: false) },
            entry: { _ in .missing })
        let outcomes = check.check(storage)
        XCTAssertEqual(outcomes.map(\.location), [.tartHome, .registryCache])
        XCTAssertEqual(outcomes.map(\.ok), [true, false])
        XCTAssertThrowsError(try check.requireReady(storage)) { error in
            XCTAssertEqual((error as? StorageProblem)?.location, .registryCache)
            XCTAssertEqual(ErrorCategory(error), .runtime)
        }
        XCTAssertNoThrow(try check.requireReady(KinhinConfig.StorageConfig()))
    }

    func testAnUnconfiguredLocationNeedsNoPreflight() {
        // Nothing is configured in the test process, so even a preflight that fails everything passes.
        XCTAssertNil(StorageLocations.current.tartHome)
        XCTAssertNoThrow(try preflight(mountPoint: nil).requireReady(.tartHome))
    }

    func testTheLiveProbeReadsTheVolumeOfTheNearestExistingAncestor() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-\(UUID().uuidString)/a/b")
        let volume = try XCTUnwrap(StoragePreflight.liveVolume(missing.path))
        XCTAssertTrue(volume.mountPoint.hasPrefix("/"), volume.mountPoint)
        XCTAssertEqual(StoragePreflight.liveEntry(missing.path), .missing)
        XCTAssertEqual(StoragePreflight.liveEntry(FileManager.default.temporaryDirectory.path), .directory)
    }
}
