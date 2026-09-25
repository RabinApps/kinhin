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
    public static let graceWindow: TimeInterval = 60 * 60

    public init(autoPrune: Bool, maxAgeDays: Int, maxGB: Int) {
        self.autoPrune = autoPrune
        self.maxAgeDays = maxAgeDays
        self.maxGB = maxGB
    }

    /// Resolves the config's optional values: defaults are auto-prune on,
    /// 30 days, 50 GB. `0` disables that axis (never expire by age / no
    /// size cap).
    public init(from config: kinhinConfig.ToolchainsConfig?) {
        let cache = config?.cache
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

    /// Walks the cache tree and prunes it per the policy. Never throws:
    /// individual failures (permissions, vanished files) are skipped and
    /// logged — pruning must never disturb a prepare or the fleet engine.
    @discardableResult
    public func prune(policy: ToolchainCachePolicy, dryRun: Bool = false, now: Date = Date()) -> ToolchainPruneReport {
        guard policy.autoPrune || dryRun else {
            return ToolchainPruneReport(entries: [], freedBytes: 0, dryRun: dryRun)
        }
        guard fileManager.fileExists(atPath: cacheRoot.path) else {
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
        let doomedLeaves = leaves.filter { doomed.contains($0.url) }.sorted { $0.url.path < $1.url.path }
        for leaf in doomedLeaves {
            let freed = leaf.size
            if !dryRun {
                do {
                    try fileManager.removeItem(at: leaf.url)
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

        // Clean up empty directories left behind (skip the root itself).
        if !dryRun {
            removeEmptyDirectories(under: cacheRoot)
        }

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

    // MARK: Internals

    /// Recursively collects regenerable leaf units under `root`. Grace
    /// window: leaves touched within the last hour are skipped entirely —
    /// they may be mid-download right now.
    private func collectLeaves(at root: URL, into leaves: inout [(url: URL, size: Int64, modified: Date)], now: Date) {
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
    private func removeEmptyDirectories(under root: URL) {
        var dirs: [URL] = []
        if let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    dirs.append(url)
                }
            }
        }
        // Deepest first so parents empty out as children are removed.
        for dir in dirs.sorted(by: { $0.path.count > $1.path.count }) {
            let contents = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? ["keep"]
            if contents.isEmpty {
                try? fileManager.removeItem(at: dir)
            }
        }
    }
}
