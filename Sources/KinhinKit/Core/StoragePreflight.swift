import Darwin
import Foundation

/// Checks a configured storage path before anything writes there: its volume is mounted, file-system ownership is
/// enabled on that volume, and the path is a directory (or can become one). A failed check stops the start with a
/// message that names the volume and the fix. Nothing ever falls back to the default location, so data never lands
/// on the internal disk while the external one is away.
///
/// Only configured paths are checked; a default location needs no preflight.
public struct StoragePreflight: Sendable {
    /// The volume holding a path, as `statfs(2)` reports it.
    public struct Volume: Equatable, Sendable {
        /// Where the volume is mounted (`/`, `/Volumes/Storage`).
        public var mountPoint: String
        /// `MNT_IGNORE_OWNERSHIP`: the volume ignores file owners (what `diskutil info` calls "Owners: Disabled").
        public var ignoresOwnership: Bool

        public init(mountPoint: String, ignoresOwnership: Bool) {
            self.mountPoint = mountPoint
            self.ignoresOwnership = ignoresOwnership
        }
    }

    /// What is at a path.
    public enum Entry: Equatable, Sendable {
        case missing
        case directory
        case notDirectory
        /// Missing, and the nearest existing ancestor (the associated path) is a file, so it can never be created.
        case blockedByFile(String)
    }

    /// The volume holding `path`, read from the nearest existing ancestor; nil when it cannot be read.
    let volume: @Sendable (String) -> Volume?
    /// What is at `path` now.
    let entry: @Sendable (String) -> Entry

    public init(
        volume: @escaping @Sendable (String) -> Volume? = { StoragePreflight.liveVolume($0) },
        entry: @escaping @Sendable (String) -> Entry = { StoragePreflight.liveEntry($0) }
    ) {
        self.volume = volume
        self.entry = entry
    }

    public static let live = StoragePreflight()

    // MARK: - Checks

    /// The first problem with `path` as the home of `location`, or nil when it is ready.
    public func problem(_ location: StorageLocation, path: String) -> StorageProblem? {
        func failure(_ what: String, fix: String) -> StorageProblem {
            StorageProblem(location: location, path: path, problem: what, fix: fix)
        }
        switch entry(path) {
        case .notDirectory:
            return failure(
                "\(path) exists but is not a directory", fix: "point \(location.configKey) at a directory")
        case .blockedByFile(let blocker):
            return failure(
                "\(blocker) is a file, so \(path) cannot be created",
                fix: "move \(blocker) aside, or point \(location.configKey) somewhere else")
        case .missing, .directory:
            break
        }
        let expected = Self.expectedMountPoint(for: path)
        guard let volume = volume(path) else {
            return failure(
                "the volume holding \(path) could not be read",
                fix: expected.map { "check that \($0) is mounted (diskutil list)" } ?? "check that the path exists")
        }
        if let expected, !Self.isMounted(expected, holding: volume) {
            return failure(
                "the volume \(expected) is not mounted",
                fix: "mount \(expected) (diskutil mount \((expected as NSString).lastPathComponent)), then retry; "
                    + "kinhin will not use the internal disk instead")
        }
        if volume.ignoresOwnership {
            var fix = "run `sudo diskutil enableOwnership \(volume.mountPoint)`"
            if location == .containerAppRoot {
                fix +=
                    ", then recopy any container files that were copied there before ownership was enabled "
                    + "(launchd rejects those plists even with the right owner and mode)"
            }
            return failure("ownership is disabled on \(volume.mountPoint)", fix: fix)
        }
        return nil
    }

    /// Every configured location's check, in `StorageLocation` order.
    public func check(_ storage: KinhinConfig.StorageConfig) -> [Outcome] {
        storage.configured.map { item in
            Outcome(
                location: item.location, path: item.path, mountPoint: volume(item.path)?.mountPoint,
                problem: problem(item.location, path: item.path))
        }
    }

    /// One location's outcome.
    public struct Outcome: Equatable, Sendable {
        public var location: StorageLocation
        public var path: String
        /// The volume holding the path, when it could be read.
        public var mountPoint: String?
        public var problem: StorageProblem?

        public var ok: Bool { problem == nil }
    }

    /// Throws the first problem among every configured location.
    public func requireReady(_ storage: KinhinConfig.StorageConfig) throws {
        if let found = check(storage).lazy.compactMap(\.problem).first { throw found }
    }

    /// Throws when `location` is configured in this process (`StorageLocations.current`) and not ready. A no-op
    /// for a location left at its default. Called right before something starts writing there.
    public func requireReady(_ location: StorageLocation) throws {
        guard let path = StorageLocations.current.path(for: location) else { return }
        if let found = problem(location, path: path) {
            Log.error("storage", found.localizedDescription)
            throw found
        }
    }

    // MARK: - Mount rules

    /// `/Volumes/<name>` for a path on a mounted volume; nil for any other path, which lives on whatever volume
    /// holds it (the boot volume, usually) and has no separate mount to wait for. `Volumes` matches in any case, as
    /// the case-insensitive boot volume resolves `/volumes/...` to the same place.
    static func expectedMountPoint(for path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2, components[0].lowercased() == "volumes" else { return nil }
        return "/Volumes/\(components[1])"
    }

    /// True when `volume` is the one mounted at `mountPoint`, or one mounted inside it, ignoring case (a configured
    /// `/Volumes/storage` names the volume mounted at `/Volumes/Storage`). An unmounted `/Volumes/Storage` resolves
    /// to `/` (or to a stray folder of that name on the boot volume), which is not.
    static func isMounted(_ mountPoint: String, holding volume: Volume) -> Bool {
        let mounted = volume.mountPoint.lowercased()
        let expected = mountPoint.lowercased()
        return mounted == expected || mounted.hasPrefix(expected + "/")
    }

    /// Whether two paths name the same directory once symlinks are resolved and a trailing slash is dropped (a
    /// directory moved to another disk and left as a symlink is the same place).
    public static func sameDirectory(_ first: String, _ second: String) -> Bool {
        func resolved(_ path: String) -> String {
            guard let real = realpath(path, nil) else { return (path as NSString).standardizingPath }
            defer { free(real) }
            return String(cString: real)
        }
        return resolved(first) == resolved(second)
    }

    // MARK: - Live probes

    /// `MNT_IGNORE_OWNERSHIP` from `<sys/mount.h>` (an alias of `MNT_UNKNOWNPERMISSIONS`).
    static let ignoreOwnershipFlag: UInt32 = 0x0020_0000

    /// `statfs(2)` on the nearest existing ancestor of `path`.
    public static func liveVolume(_ path: String) -> Volume? {
        var probe = path
        while !FileManager.default.fileExists(atPath: probe) {
            let parent = (probe as NSString).deletingLastPathComponent
            guard parent != probe, !parent.isEmpty else { return nil }
            probe = parent
        }
        var info = statfs()
        guard statfs(probe, &info) == 0 else { return nil }
        let mountPoint = withUnsafeBytes(of: info.f_mntonname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return Volume(mountPoint: mountPoint, ignoresOwnership: info.f_flags & ignoreOwnershipFlag != 0)
    }

    public static func liveEntry(_ path: String) -> Entry {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? .directory : .notDirectory
        }
        // Missing: it can be created only when its nearest existing ancestor is a directory.
        var ancestor = path
        while true {
            let parent = (ancestor as NSString).deletingLastPathComponent
            guard parent != ancestor, !parent.isEmpty else { return .missing }
            ancestor = parent
            if FileManager.default.fileExists(atPath: ancestor, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? .missing : .blockedByFile(ancestor)
            }
        }
    }
}

/// A configured storage path that is not ready: its volume is not mounted, ignores ownership, or the path is not a
/// directory. Thrown before anything starts there.
public struct StorageProblem: LocalizedError, CategorizedError, Equatable, Sendable {
    public var location: StorageLocation
    public var path: String
    /// What is wrong, without the fix.
    public var problem: String
    /// What to do about it.
    public var fix: String

    public var errorDescription: String? {
        "\(location.configKey) (\(location.title), \(path)) is not ready: \(problem) — \(fix)"
    }

    public var category: ErrorCategory { .runtime }
}
