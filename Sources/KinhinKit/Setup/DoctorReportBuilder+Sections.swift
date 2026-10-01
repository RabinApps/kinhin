import Foundation

// MARK: - Section mappers (filesystem reads and JSON section shapes)

extension DoctorReportBuilder {
    /// Measures the host toolchain cache: usability, total bytes, and the
    /// per-ecosystem breakdown for the directories the config's selection
    /// maps to (or all populated top-level directories when nothing is
    /// selected). Pure filesystem reads — never creates or deletes anything.
    /// Public so the human doctor prints exactly the JSON document's data.
    public static func toolchainCacheSection(config: KinhinConfig?) -> DoctorReport.ToolchainCacheSection {
        let root = Paths.toolchainCache
        let fm = FileManager.default
        var isDir: ObjCBool = false
        var isUsable = fm.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
        if isUsable, !fm.isWritableFile(atPath: root.path) {
            isUsable = false
        }
        guard isUsable else {
            let shareCacheOn = config?.toolchains?.shareCache ?? false
            return DoctorReport.ToolchainCacheSection(
                root: root.path, usable: false, sharedWithRunners: shareCacheOn,
                warning: shareCacheOn, totalBytes: 0, ecosystems: []
            )
        }

        // The subdirectories the config's toolchains selection maps to
        // (Linux path irrelevant here — subdirectories are shared).
        let selected: [String]?
        if let toolchains = config?.toolchains {
            let selection = ToolchainCatalog.selection(from: toolchains)
            let dirs = selection.cacheEnvs.map(\.subdirectory)
            selected = dirs.isEmpty ? nil : dirs
        } else {
            selected = nil
        }

        var ecosystems: [DoctorReport.ToolchainCacheSection.Ecosystem] = []
        var total: Int64 = 0
        if let selected {
            for directory in selected {
                let bytes = Self.directorySize(at: root.appendingPathComponent(directory))
                ecosystems.append(.init(directory: directory, bytes: bytes))
                total += bytes
            }
        } else {
            // No selection: report every populated top-level directory. An
            // unreadable cache root simply reports as empty ("no cache yet").
            let children =
                (try? fm.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey])) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let bytes = Self.directorySize(at: child)
                guard bytes > 0 else { continue }
                ecosystems.append(.init(directory: child.lastPathComponent, bytes: bytes))
                total += bytes
            }
        }
        let shareCacheOn = config?.toolchains?.shareCache ?? false
        let warning = shareCacheOn && total == 0
        return DoctorReport.ToolchainCacheSection(
            root: root.path, usable: true, sharedWithRunners: shareCacheOn,
            warning: warning, totalBytes: total, ecosystems: ecosystems
        )
    }

    /// Recursive byte size of a directory (0 when missing). Follows the
    /// same pruning-friendly convention: regular files only.
    static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            // A file that cannot be stat'ed mid-walk is skipped; the size
            // report is advisory, not a correctness boundary.
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// The isolation and transport posture of the config: whether runner VMs
    /// are Softnet-isolated, which accounts send a token over plain http,
    /// and whether the shared cache is writable by every job.
    public static func securitySection(
        config: KinhinConfig?, softnetInstalled: Bool? = nil, tartHealthy: Bool = true
    ) -> DoctorReport.SecuritySection? {
        guard let config else { return nil }
        let enabled = config.tartSoftnet == true
        let installed = softnetInstalled ?? (Paths.findExecutable(named: "softnet", override: nil) != nil)
        var warnings: [String] = []
        var fix: String?
        if enabled, !installed {
            fix = "brew install cirruslabs/cli/softnet (then follow Tart's Softnet setup)"
        } else if !enabled, tartHealthy {
            warnings.append(
                "runner VMs share one virtual network (tart_softnet is off): a job can reach other runner VMs and your LAN. Fine for trusted code; for outside PRs set tart_softnet: true (docs/security.md)"
            )
        }
        let insecure = config.accounts.filter(\.sendsTokenOverPlainHTTP).map(\.name)
        for name in insecure {
            warnings.append(
                "account '\(name)' sends its access token over plain http (allow_insecure_http): use https if you can")
        }
        let sharedCache = config.toolchains?.shareCache ?? false
        if sharedCache {
            warnings.append(
                "toolchains.share_cache is on: the cache is writable by every job and holds binaries other jobs run. Keep it off for untrusted PRs (docs/security.md)"
            )
        }
        return DoctorReport.SecuritySection(
            softnetEnabled: enabled, softnetInstalled: installed, ok: fix == nil, fix: fix,
            insecureHTTPAccounts: insecure, sharedCacheWritable: sharedCache, warnings: warnings)
    }

    /// Maps CLTState to the JSON section, carrying the shared repair lines.
    static func cltSection(from state: CLTState) -> DoctorReport.CLTSection {
        switch state {
        case .ok(let version):
            return DoctorReport.CLTSection(state: "ok", version: version, ok: true, fixCommand: nil, fixHint: nil)
        case .outdated(let version, _):
            return DoctorReport.CLTSection(
                state: "outdated", version: version, ok: false,
                fixCommand: CLTRepair.commandLine, fixHint: CLTRepair.fallbackHint
            )
        case .missing:
            return DoctorReport.CLTSection(
                state: "missing", version: nil, ok: false,
                fixCommand: CLTRepair.commandLine, fixHint: nil
            )
        case .unselected:
            return DoctorReport.CLTSection(
                state: "unselected", version: nil, ok: false,
                fixCommand: CLTRepair.commandLine, fixHint: nil
            )
        }
    }

    /// Maps TartHealth to the JSON section with the ordered repair lines.
    static func tartSection(from health: TartHealth) -> DoctorReport.TartSection {
        switch health {
        case .healthy:
            return DoctorReport.TartSection(state: "healthy", ok: true, reason: nil, repairCommands: [])
        case .missing:
            return DoctorReport.TartSection(
                state: "missing", ok: false, reason: nil,
                repairCommands: TartHealthProbe.repairs(for: .missing).map(\.commandLine)
            )
        case .killedOnLaunch:
            return DoctorReport.TartSection(
                state: "killedOnLaunch", ok: false,
                reason: "Gatekeeper blocked the un-notarized binary (openai/homebrew-tools#27)",
                repairCommands: TartHealthProbe.repairs(for: .killedOnLaunch).map(\.commandLine)
            )
        case .broken(let reason):
            return DoctorReport.TartSection(
                state: "broken", ok: false, reason: reason,
                repairCommands: TartHealthProbe.repairs(for: .broken(reason)).map(\.commandLine)
            )
        }
    }
}
