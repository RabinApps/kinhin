import Foundation

// MARK: - Cache policy

/// Effective cache-expiry policy resolved from the config (defaults for
/// absent values), plus the built-in safety rail: entries touched within the
/// last hour are never evicted, so a prune can never race a live download.
public struct ToolchainCachePolicy: Sendable, Equatable {
    public let autoPrune: Bool
    public let maxAgeDays: Int
    public let maxGB: Int

    /// Entries modified within this window are untouchable (a live download
    /// or an in-flight install may be writing them right now).
    static let graceWindow: TimeInterval = 60 * 60

    public init(autoPrune: Bool, maxAgeDays: Int, maxGB: Int) {
        self.autoPrune = autoPrune
        self.maxAgeDays = maxAgeDays
        self.maxGB = maxGB
    }

    /// Resolves the config's optional values: defaults are auto-prune on,
    /// 30 days, 50 GB. `0` disables that axis (never expire by age / no
    /// size cap).
    public init(from cache: KinhinConfig.ToolchainCacheConfig?) {
        self.init(
            autoPrune: cache?.autoPrune ?? true,
            maxAgeDays: cache?.maxAgeDays ?? 30,
            maxGB: cache?.maxGB ?? 50
        )
    }
}

// MARK: - Prune report

/// One ecosystem directory's outcome (e.g. `npm/`, `go/mod/`).
public struct ToolchainPruneEntry: Sendable, Equatable {
    public let path: String
    public let freedBytes: Int64
    public let deleted: Bool  // false in dry-run mode

    public init(path: String, freedBytes: Int64, deleted: Bool) {
        self.path = path
        self.freedBytes = freedBytes
        self.deleted = deleted
    }
}

public struct ToolchainPruneReport: Sendable, Equatable {
    public let entries: [ToolchainPruneEntry]
    public let freedBytes: Int64
    public let dryRun: Bool

    public init(entries: [ToolchainPruneEntry], freedBytes: Int64, dryRun: Bool) {
        self.entries = entries
        self.freedBytes = freedBytes
        self.dryRun = dryRun
    }
}

// MARK: - Pruner

/// Auto-expiry for the shared toolchain cache: everything under the cache
/// root is regenerable by design (mise's own docs bless wiping its cache
/// dir), so pruning is safe. It only ever touches the host cache — never
/// baked images or running VMs.
///
/// Policy (per `ToolchainCachePolicy`): delete entries whose last-use time
/// (mtime — atime is unreliable on APFS; writes refresh mtime, so active
/// entries protect themselves) is older than `maxAgeDays`; then evict
/// least-recently-used entries while the total size exceeds `maxGB`.
public struct ToolchainCachePruner {
    let cacheRoot: URL
    let fileManager: FileManager

    public init(cacheRoot: URL = Paths.toolchainCache, fileManager: FileManager = .default) {
        self.cacheRoot = cacheRoot
        self.fileManager = fileManager
    }

    /// Records when the last real sweep finished (next to the cache, not in
    /// it, so it is never mistaken for a cache entry).
    var sweepMarker: URL {
        cacheRoot.deletingLastPathComponent().appendingPathComponent(".\(cacheRoot.lastPathComponent)-last-sweep")
    }

    /// Walks the cache tree and prunes it per the policy. Never throws:
    /// individual failures (permissions, vanished files) are skipped and
    /// logged — pruning must never disturb a prepare or the fleet engine.
    ///
    /// `minInterval` rate-limits sweeps: when the previous sweep finished
    /// less than that many seconds ago, nothing is walked (every image
    /// prepare asks; a full tree walk each time is wasted). `0` always
    /// sweeps, and a dry run never skips.
    @discardableResult
    public func prune(
        policy: ToolchainCachePolicy, dryRun: Bool = false, now: Date = Date(), minInterval: TimeInterval = 0
    ) -> ToolchainPruneReport {
        guard policy.autoPrune || dryRun else {
            return ToolchainPruneReport(entries: [], freedBytes: 0, dryRun: dryRun)
        }
        guard fileManager.fileExists(atPath: cacheRoot.path) else {
            return ToolchainPruneReport(entries: [], freedBytes: 0, dryRun: dryRun)
        }
        if !dryRun, minInterval > 0, let last = lastSweep(), now.timeIntervalSince(last) < minInterval {
            return ToolchainPruneReport(entries: [], freedBytes: 0, dryRun: dryRun)
        }

        // Leaves = regenerable units: files at any depth and empty
        // directories. Ecosystem subdirectories (e.g. `go/`, `npm/`) are
        // only containers and are never deleted wholesale.
        var leaves: [(url: URL, size: Int64, modified: Date)] = []
        collectLeaves(at: cacheRoot, into: &leaves, now: now)

        let totalBytes = leaves.reduce(Int64(0)) { $0 + $1.size }
        var doomed = Set<URL>()

        // 1. Age expiry.
        if policy.maxAgeDays > 0 {
            let cutoff = now.addingTimeInterval(-TimeInterval(policy.maxAgeDays) * 86_400)
            for leaf in leaves where leaf.modified < cutoff {
                doomed.insert(leaf.url)
            }
        }

        // 2. LRU eviction down to the size cap (oldest use first). The
        // already-doomed bytes count toward the total.
        if policy.maxGB > 0 {
            let cap = Int64(policy.maxGB) * 1_073_741_824
            var running = totalBytes
            let byAge = leaves.sorted { $0.modified < $1.modified }
            for leaf in byAge where running > cap {
                guard !doomed.contains(leaf.url) else { continue }
                doomed.insert(leaf.url)
                running -= leaf.size
            }
        }

        // Execute (or simulate) the deletions, newest-last for a stable report.
        var entries: [ToolchainPruneEntry] = []
        let resolvedRoot = Self.resolvedPath(of: cacheRoot)  // once, not per deleted leaf
        let doomedLeaves = leaves.filter { doomed.contains($0.url) }.sorted { $0.url.path < $1.url.path }
        for leaf in doomedLeaves {
            let freed = leaf.size
            if !dryRun {
                do {
                    try removeWithoutFollowingLinks(leaf.url, isDirectory: false, resolvedRoot: resolvedRoot)
                } catch {
                    Log.warn("cache", "could not prune \(leaf.url.path): \(error.localizedDescription)")
                    continue
                }
            }
            entries.append(
                ToolchainPruneEntry(
                    path: leaf.url.path.replacingOccurrences(of: cacheRoot.path + "/", with: ""),
                    freedBytes: freed,
                    deleted: !dryRun
                ))
        }

        // Clean up empty directories left behind (skip the root itself) —
        // only deletions can leave one, so a sweep that removed nothing
        // skips the second tree walk.
        if !dryRun, !entries.isEmpty {
            removeEmptyDirectories(under: cacheRoot, resolvedRoot: resolvedRoot)
        }
        if !dryRun, minInterval > 0 { recordSweep(at: now) }

        let freed = entries.reduce(Int64(0)) { $0 + $1.freedBytes }
        if freed > 0 || !entries.isEmpty {
            Log.info(
                "cache",
                "\(dryRun ? "would prune" : "pruned") \(entries.count) entr\(entries.count == 1 ? "y" : "ies") (\(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)))"
            )
        }
        return ToolchainPruneReport(entries: entries, freedBytes: freed, dryRun: dryRun)
    }

    /// Current total size of the cache (for `kinhin toolchains`).
    public func totalBytes() -> Int64 {
        var total: Int64 = 0
        var leaves: [(url: URL, size: Int64, modified: Date)] = []
        collectLeaves(at: cacheRoot, into: &leaves, now: Date())
        total = leaves.reduce(0) { $0 + $1.size }
        return total
    }

    // MARK: - Internals

    private func lastSweep() -> Date? {
        // A missing or unreadable marker just means "sweep now".
        (try? fileManager.attributesOfItem(atPath: sweepMarker.path))?[.modificationDate] as? Date
    }

    private func recordSweep(at date: Date) {
        bestEffort("cache", "recording the sweep time") {
            let data = Data(ISO8601DateFormatter().string(from: date).utf8)
            try data.write(to: sweepMarker, options: .atomic)
            try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: sweepMarker.path)
        }
    }

    /// The real (symlink-resolved) form of `url`; `resolvingSymlinksInPath`
    /// strips /private, so ask realpath.
    static func resolvedPath(of url: URL) -> String? {
        realpath(url.path, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        }
    }

    /// Recursively collects regenerable leaf units under `root`. Grace
    /// window: leaves touched within the last hour are skipped entirely —
    /// they may be mid-download right now.
    private func collectLeaves(at root: URL, into leaves: inout [(url: URL, size: Int64, modified: Date)], now: Date) {
        // An unreadable cache root simply means "nothing to prune" this sweep.
        guard
            let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [],
                errorHandler: { url, error in
                    Log.warn("cache", "skipping \(url.path) during cache walk: \(error.localizedDescription)")
                    return true
                })
        else { return }

        for case let url as URL in enumerator {
            // An entry that vanished or cannot be stat'ed mid-walk is simply not pruned this sweep.
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            guard let values else { continue }
            let isDir = values.isDirectory ?? false

            // Directories are containers: always descend into them (their
            // mtime changes whenever an entry is added, so gating traversal
            // on it would skip freshly-written subtrees), never prunable
            // directly — only empty ones go, after deletions.
            guard !isDir else { continue }

            let modified = values.contentModificationDate ?? .distantPast
            // Grace window: a file just written may be mid-download.
            guard now.timeIntervalSince(modified) > ToolchainCachePolicy.graceWindow else { continue }

            let size = Int64(values.fileSize ?? 0)
            leaves.append((url, size, modified))
        }
    }

    /// Removes now-empty directories (deepest first), keeping `root` itself.
    private func removeEmptyDirectories(under root: URL, resolvedRoot: String?) {
        var dirs: [URL] = []
        if let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in enumerator {
                // Unreadable entries are treated as non-directories and kept.
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    dirs.append(url)
                }
            }
        }
        // Deepest first so parents empty out as children are removed.
        for dir in dirs.sorted(by: { $0.path.count > $1.path.count }) {
            // An unlistable directory reads as non-empty, so it is kept.
            let contents = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? ["keep"]
            if contents.isEmpty {
                bestEffort("cache", "removing empty directory \(dir.path)") {
                    try removeWithoutFollowingLinks(dir, isDirectory: true, resolvedRoot: resolvedRoot)
                }
            }
        }
    }

    // MARK: - Symlink-safe removal

    /// The cache is writable from guest VMs when `share_cache` is on, so a job can
    /// swap a directory in the tree for a symlink after the walk and before the
    /// delete. `removeItem` would then follow it and delete a host file. This walks
    /// from the cache root one component at a time with `O_NOFOLLOW` and unlinks
    /// the final entry relative to its parent descriptor, so a link anywhere on the
    /// path makes the removal fail instead of escaping the cache.
    func removeWithoutFollowingLinks(_ url: URL, isDirectory: Bool, resolvedRoot: String? = nil) throws {
        // The enumerator may report either the root as given or its resolved form
        // (/var vs /private/var); both name the same trusted root. Callers
        // removing many entries resolve it once and pass it in.
        let resolvedRoot = resolvedRoot ?? Self.resolvedPath(of: cacheRoot)
        let prefixes = ([cacheRoot.path] + [resolvedRoot].compactMap { $0 }).map { $0 + "/" }
        guard let prefix = prefixes.first(where: { url.path.hasPrefix($0) }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let components = url.path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard let last = components.last, !components.contains(".."), !components.contains(".") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        // The root is the user's own directory (it may itself be a link); everything below it is not trusted.
        var directory = open(cacheRoot.path, O_RDONLY | O_DIRECTORY)
        guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            close(directory)
            directory = next
        }
        guard unlinkat(directory, last, isDirectory ? AT_REMOVEDIR : 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
