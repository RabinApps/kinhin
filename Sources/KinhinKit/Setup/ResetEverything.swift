import Foundation

/// `kinhin reset` / the app's "Reset kinhin…": wipes kinhin's local state by
/// scope, irreversibly. Both surfaces show the exact plan (``ResetPlan/describe()``)
/// and confirm twice before ``ResetEverything/execute(_:tart:shell:stopFleet:)``
/// runs; there is no undo and no Trash.
public enum ResetScope: String, CaseIterable, Sendable {
    /// The config file (+ backup), every Keychain token, logs and local state.
    /// The daemon, VMs, images and the toolchain cache are kept.
    case config
    /// Stops the fleet and removes the daemon LaunchAgent (both labels).
    /// Everything else is kept.
    case daemon
    /// Everything: both scopes above plus all tart VMs (runner and scratch),
    /// every baked image, the toolchain cache and the whole support directory.
    case all

    public var label: String {
        switch self {
        case .config: return "Config & credentials"
        case .daemon: return "Daemon"
        case .all: return "Everything"
        }
    }

    /// One-line summary for menus and the scope-picker dialog.
    public var summary: String {
        switch self {
        case .config:
            return
                "Delete the config file, every stored token, logs and local state. VMs, images, the toolchain cache and the daemon are kept."
        case .daemon:
            return
                "Stop the fleet and remove the background daemon. Everything else is kept; `kinhin daemon install` reinstalls it."
        case .all:
            return
                "A factory reset: config, tokens, logs, state, the daemon, all VMs and images, and the toolchain cache."
        }
    }

    /// Whether the scope erases the config and credentials (and so resets the
    /// app's preferences and login item with them).
    public var includesConfig: Bool { self != .daemon }

    /// Whether the scope touches the daemon installation.
    var includesDaemon: Bool { self != .config }
}

/// What a reset will remove, in the order ``ResetEverything/execute`` removes
/// it. Built by ``ResetEverything/plan(scope:configURL:supportRoot:isDaemonAlive:tart:)``
/// (reads only), shown to the user for confirmation, then executed.
public struct ResetPlan: Equatable, Sendable {
    public let scope: ResetScope
    /// The config could not be read (reset may be the reason it is broken);
    /// image names then come from the defaults and say so.
    public var configBroken = false
    /// config.yaml and its backup, when they exist.
    public var configFiles: [URL] = []
    /// Keychain accounts with a stored token, across kinhin's services
    /// (`legacy:` prefixes the pre-rename service's items).
    public var keychainAccounts: [String] = []
    public var daemonInstalled = false
    /// A daemon was alive when the plan was built (any scope — the config
    /// scope uses this to warn that a running daemon keeps serving with its
    /// in-memory token; only includesDaemon scopes act on it).
    public var daemonAlive = false
    /// The "everything" scope's VM/image/cache inventory; nil otherwise.
    public var cleanup: CleanupPlan?
    /// The support directory the `all` scope empties (and where logs/state
    /// live for the config scope).
    public var supportRoot: URL
    /// The tart path from the config, so `execute` can rebuild the controller
    /// it needs for VM deletion.
    public var tartPath: String?

    public init(scope: ResetScope, supportRoot: URL) {
        self.scope = scope
        self.supportRoot = supportRoot
    }

    /// The logs and per-VM state directories (config and all scopes).
    public var logsDirectory: URL { supportRoot.appendingPathComponent("logs", isDirectory: true) }
    public var stateDirectory: URL { supportRoot.appendingPathComponent("state", isDirectory: true) }

    /// The confirmation text both surfaces show before the typed-word step.
    public func describe() -> String {
        var lines: [String] = ["kinhin reset — \(scope.label)"]
        if scope.includesDaemon {
            if daemonAlive { lines.append("  stop the fleet (the running daemon)") }
            lines.append("  remove the daemon LaunchAgent (com.kinhin.daemon)")
        }
        if let cleanup {
            let detail = cleanup.describe(willDelete: true).split(separator: "\n").map { "  \($0)" }
            lines.append(contentsOf: detail)
            lines.append("  empty \(supportRoot.path)")
        } else if scope == .config {
            for file in configFiles { lines.append("  delete \(file.path)") }
            lines.append("  delete \(logsDirectory.path) and \(stateDirectory.path)")
            lines.append("  (the daemon, VMs, images and the toolchain cache are kept)")
        }
        if !keychainAccounts.isEmpty {
            lines.append(
                "  delete \(keychainAccounts.count) keychain token(s): \(keychainAccounts.joined(separator: ", "))")
        }
        if scope == .config, daemonAlive {
            lines.append("  note: the running daemon keeps serving with its in-memory token until restarted")
        }
        if configBroken, scope == .all {
            lines.append("  note: the config could not be read — image names come from the defaults")
        }
        lines.append("  this cannot be undone")
        return lines.joined(separator: "\n")
    }
}

/// The reset engine behind `kinhin reset` and the app's "Reset kinhin…".
/// Planning reads only; execution is ordered so nothing keeps recreating what
/// another step just deleted: fleet first, then the LaunchAgent, then VMs and
/// files, then the Keychain.
public enum ResetEverything {
    /// Builds the plan for one scope. Never throws for missing state — an
    /// unreadable config degrades to the defaults (flagged in the plan), a
    /// missing tart contributes no VMs, an unreadable Keychain leaves the
    /// token list empty (execution warns).
    public static func plan(
        scope: ResetScope,
        configURL: URL = Paths.config,
        supportRoot: URL? = nil,
        isDaemonAlive: @escaping @Sendable () -> Bool = { RPCClient.isDaemonAlive() },
        tart: (any TartControlling)? = nil
    ) async -> ResetPlan {
        let supportRoot = supportRoot ?? Paths.appSupport
        var plan = ResetPlan(scope: scope, supportRoot: supportRoot)
        let config: KinhinConfig
        do {
            config = try ConfigLoader.load(from: configURL)
        } catch let error as ConfigError {
            config = .default
            // A missing file is the normal "nothing configured yet" state;
            // anything else (bad YAML, unreadable) is flagged in the plan.
            switch error {
            case .notFound: break
            default: plan.configBroken = true
            }
        } catch {
            config = .default
            plan.configBroken = true
        }
        plan.tartPath = config.tartPath

        let fm = FileManager.default
        if scope.includesConfig {
            for url in [configURL, configURL.appendingPathExtension("bak")] where fm.fileExists(atPath: url.path) {
                plan.configFiles.append(url)
            }
        }
        plan.daemonInstalled = scope.includesDaemon && Daemon.agentPlistURL != nil
        plan.daemonAlive = isDaemonAlive()
        if scope == .all {
            let controller = tart ?? (try? TartController(configuredPath: config.tartPath))
            let cacheRoot = supportRoot.appendingPathComponent(ToolchainCacheMount.hostDirectoryName, isDirectory: true)
            // A tart that cannot be listed contributes no VMs; the cache is
            // still counted and the directory still emptied.
            plan.cleanup =
                (try? await CleanupPlan.plan(
                    targets: .all, tart: controller, baseImage: config.image,
                    namedImages: config.images.map(\.name), cacheRoot: cacheRoot)) ?? CleanupPlan()
        }
        if scope.includesConfig {
            plan.keychainAccounts = (try? KeychainTokenStore.accounts()) ?? []
        }
        return plan
    }

    /// Runs the plan. Returns one report line per completed step (for stdout
    /// or the app's status line). Per-item failures are logged and reported
    /// instead of stranding the rest of the reset; the LaunchAgent removal is
    /// the only step allowed to throw (a surviving KeepAlive daemon would
    /// recreate everything the reset just deleted). The daemon uninstall and
    /// directory re-creation are injectable so tests never touch the real
    /// LaunchAgents or the developer's support directory.
    @discardableResult
    public static func execute(
        _ plan: ResetPlan,
        tart: (any TartControlling)? = nil,
        shell: ShellRunning = Shell(),
        stopFleet: (@Sendable () async -> Void)? = nil,
        uninstallDaemon: (@Sendable () async throws -> Void)? = nil,
        ensureDirs: (@Sendable () -> Void)? = nil
    ) async throws -> [String] {
        var report: [String] = []
        let fm = FileManager.default

        // 1. Stop the fleet so VMs tear down and nothing recreates state.
        if plan.scope.includesDaemon, plan.daemonAlive {
            if let stopFleet {
                await stopFleet()
            } else {
                await stopDaemonFleetIfAlive()
            }
            report.append("stopped the fleet")
        }

        // 2. Remove the LaunchAgent before touching anything it could revive.
        if plan.scope.includesDaemon {
            if let uninstallDaemon {
                try await uninstallDaemon()
            } else {
                try await Daemon.stopAndUninstall(shell: shell)
            }
            report.append("removed the daemon LaunchAgent")
        }

        // 3. VMs, images, toolchain cache (the "everything" scope). One bad VM
        //    must not strand the others: best-effort per item.
        if let cleanup = plan.cleanup {
            let controller =
                tart ?? (try? TartController(configuredPath: plan.tartPath))
            if let controller {
                for vm in cleanup.vms + cleanup.scratchVMs {
                    await bestEffortAsync("reset", "deleting \(vm)") {
                        try? await controller.stop(name: vm)  // not running is what we want
                        try await controller.delete(name: vm)
                    }
                }
                for image in cleanup.images {
                    await bestEffortAsync("reset", "deleting image \(image)") {
                        try await controller.delete(name: image)
                    }
                }
            } else if !cleanup.vms.isEmpty || !cleanup.images.isEmpty {
                report.append(
                    "warning: tart is not available — \(cleanup.vms.count + cleanup.images.count) VM(s)/image(s) were left on disk (re-run `kinhin cleanup --yes`)"
                )
            }
            if cleanup.cacheBytes != nil {
                let cacheRoot = plan.supportRoot.appendingPathComponent(
                    ToolchainCacheMount.hostDirectoryName, isDirectory: true)
                bestEffort("reset", "emptying the toolchain cache") {
                    let entries = try fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)
                    for entry in entries { try fm.removeItem(at: entry) }
                }
            }
            let removed =
                "removed \(cleanup.vms.count + cleanup.scratchVMs.count) VM(s) and \(cleanup.images.count) image(s)"
            report.append(removed)
        }

        // 4. Files: the whole support directory (everything), or config +
        //    logs + state (config scope). The directory itself is kept and
        //    re-created 0700 so the next launch starts clean.
        if plan.scope.includesConfig {
            for url in plan.configFiles {
                bestEffort("reset", "deleting \(url.lastPathComponent)") { try fm.removeItem(at: url) }
            }
            if plan.scope == .all {
                let entries = (try? fm.contentsOfDirectory(at: plan.supportRoot, includingPropertiesForKeys: nil)) ?? []
                for entry in entries {
                    bestEffort("reset", "deleting \(entry.lastPathComponent)") { try fm.removeItem(at: entry) }
                }
            } else {
                for directory in [plan.logsDirectory, plan.stateDirectory] {
                    bestEffort("reset", "deleting \(directory.lastPathComponent)") { try fm.removeItem(at: directory) }
                }
            }
            (ensureDirs ?? { Paths.ensureSupportDirectories() })()
            report.append(plan.scope == .all ? "emptied \(plan.supportRoot.path)" : "removed config, logs and state")
        }

        // 5. Tokens last: once the files are gone a surviving token is the
        //    only way back in, and a locked Keychain must not hide that.
        if plan.scope.includesConfig {
            do {
                let removed = try KeychainTokenStore.deleteAll()
                report.append(
                    removed.isEmpty ? "no stored tokens found" : "removed \(removed.count) keychain token(s)")
            } catch {
                Log.warn("reset", "keychain wipe failed: \(error.localizedDescription)")
                report.append(
                    "warning: the keychain could not be wiped (\(error.localizedDescription)) — remove the tokens with `kinhin auth clear`"
                )
            }
        }
        Log.info("reset", "kinhin was reset (scope: \(plan.scope.rawValue)) — this cannot be undone")
        return report
    }

    /// The production fleet stop: tell a running daemon to stop its engine
    /// (VMs tear down). Best-effort — an unreachable daemon is handled by the
    /// LaunchAgent removal and tart's stop-before-delete.
    private static func stopDaemonFleetIfAlive() async {
        guard RPCClient.isDaemonAlive() else { return }
        do {
            let response = try RPCClient().command(.stop)
            if !response.ok { Log.warn("reset", "the daemon refused to stop: \(response.error ?? "no reason")") }
        } catch {
            Log.warn("reset", "could not stop the daemon: \(error.localizedDescription)")
        }
    }
}
