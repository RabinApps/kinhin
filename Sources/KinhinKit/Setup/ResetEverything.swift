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
    /// image names and the tart path then come from the defaults and say so.
    public var configBroken = false
    /// Why the config could not be read, when ``configBroken``.
    public var configError: String?
    /// What planning could not inventory, so execution cannot remove it.
    /// Never silently dropped: both surfaces show these before the user
    /// confirms, and execution carries them into ``ResetReport/leftBehind``.
    public var planningProblems: [PlanningProblem] = []
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

    /// Something the plan could not inventory, and so will not remove.
    public struct PlanningProblem: Equatable, Sendable {
        public enum Area: Equatable, Sendable {
            /// tart could not be run or listed: VMs and images are not removed.
            case tart
            /// The Keychain could not be read: the tokens were not listed
            /// (execution still tries the wipe, and drops this problem if it
            /// succeeds).
            case keychain
        }

        public let area: Area
        /// One user-readable line naming the failure and what it leaves behind.
        public let message: String

        public init(area: Area, message: String) {
            self.area = area
            self.message = message
        }
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
            let reason = configError.map { " (\($0))" } ?? ""
            lines.append(
                "  note: the config could not be read\(reason) — the tart path and image names come from the defaults")
        }
        for problem in planningProblems {
            lines.append("  warning: \(problem.message)")
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
    /// Builds the plan for one scope. Throws only `CancellationError`; missing
    /// or unreadable state is recorded instead of hidden: an unreadable config
    /// degrades to the defaults (``ResetPlan/configBroken``), and a tart that
    /// cannot be run or listed, or a Keychain that cannot be read, becomes a
    /// ``ResetPlan/planningProblems`` entry. A Mac with no tart at all (and
    /// none configured) has no VMs to remove, so that is not a problem.
    /// `keychainAccounts` is injectable so tests can fail the Keychain read.
    public static func plan(
        scope: ResetScope,
        configURL: URL = Paths.config,
        supportRoot: URL? = nil,
        isDaemonAlive: @escaping @Sendable () -> Bool = { RPCClient.isDaemonAlive() },
        tart: (any TartControlling)? = nil,
        keychainAccounts: () throws -> [String] = { try KeychainTokenStore.accounts() }
    ) async throws -> ResetPlan {
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
            default:
                plan.configBroken = true
                plan.configError = error.localizedDescription
            }
        } catch {
            config = .default
            plan.configBroken = true
            plan.configError = error.localizedDescription
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
            let cacheRoot = supportRoot.appendingPathComponent(ToolchainCacheMount.hostDirectoryName, isDirectory: true)
            let controller = tart ?? tartController(for: config, plan: &plan)
            do {
                plan.cleanup = try await CleanupPlan.plan(
                    targets: .all, tart: controller, baseImage: config.image,
                    namedImages: config.images.map(\.name), cacheRoot: cacheRoot)
            } catch let error as CancellationError {
                throw error
            } catch {
                // A tart that cannot be listed contributes no VMs, and the
                // plan says so; the cache is still counted and the directory
                // still emptied.
                Log.warn("reset", "listing tart VMs failed: \(error.localizedDescription)")
                plan.planningProblems.append(
                    .init(
                        area: .tart,
                        message:
                            "could not list Tart VMs (\(error.localizedDescription)); VMs and images were not removed"))
                plan.cleanup = try await CleanupPlan.plan(
                    targets: CleanupPlan.Targets(cache: true), tart: nil, baseImage: config.image, cacheRoot: cacheRoot)
            }
        }
        if scope.includesConfig {
            do {
                plan.keychainAccounts = try keychainAccounts()
            } catch {
                Log.warn("reset", "reading the keychain failed: \(error.localizedDescription)")
                plan.planningProblems.append(
                    .init(
                        area: .keychain,
                        message:
                            "could not read the Keychain (\(error.localizedDescription)); stored tokens were not listed and may not be removed"
                    ))
            }
        }
        return plan
    }

    /// The production tart for the "everything" scope. No tart on this Mac
    /// (and none configured, from a readable config) means there are no tart
    /// VMs or images to remove; any other failure is a planning problem.
    private static func tartController(for config: KinhinConfig, plan: inout ResetPlan) -> (any TartControlling)? {
        do {
            return try TartController(configuredPath: config.tartPath)
        } catch TartError.missingBinary where config.tartPath == nil && !plan.configBroken {
            Log.info("reset", "tart is not installed; no VMs or images to remove")
            return nil
        } catch {
            Log.warn("reset", "tart is not available: \(error.localizedDescription)")
            plan.planningProblems.append(
                .init(
                    area: .tart,
                    message: "could not run tart (\(error.localizedDescription)); VMs and images were not removed"))
            return nil
        }
    }

    /// Runs the plan and reports what it did and what it left behind (for the
    /// CLI's output or the app's status line). Per-item failures are logged
    /// and reported in ``ResetReport/leftBehind`` instead of stranding the
    /// rest of the reset, and the plan's ``ResetPlan/planningProblems`` lead
    /// that list. The LaunchAgent removal is the only step allowed to throw (a
    /// surviving KeepAlive daemon would recreate everything the reset just
    /// deleted); cancellation propagates. The daemon uninstall and directory
    /// re-creation are injectable so tests never touch the real LaunchAgents
    /// or the developer's support directory.
    @discardableResult
    public static func execute(
        _ plan: ResetPlan,
        tart: (any TartControlling)? = nil,
        shell: ShellRunning = Shell(),
        stopFleet: (@Sendable () async -> Void)? = nil,
        uninstallDaemon: (@Sendable () async throws -> Void)? = nil,
        ensureDirs: (@Sendable () -> Void)? = nil
    ) async throws -> ResetReport {
        var report = ResetReport()
        // The Keychain problem is re-judged by the wipe in step 5.
        report.leftBehind = plan.planningProblems.filter { $0.area != .keychain }.map(\.message)
        let fm = FileManager.default

        // 1. Stop the fleet so VMs tear down and nothing recreates state.
        if plan.scope.includesDaemon, plan.daemonAlive {
            if let stopFleet {
                await stopFleet()
            } else {
                await stopDaemonFleetIfAlive()
            }
            report.completed.append("stopped the fleet")
        }

        // 2. Remove the LaunchAgent before touching anything it could revive.
        if plan.scope.includesDaemon {
            if let uninstallDaemon {
                try await uninstallDaemon()
            } else {
                try await Daemon.stopAndUninstall(shell: shell)
            }
            report.completed.append("removed the daemon LaunchAgent")
        }

        // 3. VMs, images, toolchain cache (the "everything" scope). One bad VM
        //    must not strand the others: each item is attempted and reported.
        if let cleanup = plan.cleanup {
            try await removeVMsAndImages(cleanup, plan: plan, tart: tart, report: &report)
            if cleanup.cacheBytes != nil {
                let cacheRoot = plan.supportRoot.appendingPathComponent(
                    ToolchainCacheMount.hostDirectoryName, isDirectory: true)
                try attempt("empty the toolchain cache", &report) {
                    let entries = try fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)
                    for entry in entries { try fm.removeItem(at: entry) }
                }
            }
        }

        // 4. Files: the whole support directory (everything), or config +
        //    logs + state (config scope). The directory itself is kept and
        //    re-created 0700 so the next launch starts clean.
        if plan.scope.includesConfig {
            for url in plan.configFiles {
                try attempt("delete \(url.lastPathComponent)", &report) { try fm.removeItem(at: url) }
            }
            if plan.scope == .all {
                // A directory that cannot be listed is reported, not read as
                // "already empty".
                do {
                    let entries = try fm.contentsOfDirectory(at: plan.supportRoot, includingPropertiesForKeys: nil)
                    for entry in entries {
                        try attempt("delete \(entry.lastPathComponent)", &report) { try fm.removeItem(at: entry) }
                    }
                    report.completed.append("emptied \(plan.supportRoot.path)")
                } catch let error as CancellationError {
                    throw error
                } catch {
                    Log.warn("reset", "listing \(plan.supportRoot.path) failed: \(error.localizedDescription)")
                    report.leftBehind.append(
                        "could not list \(plan.supportRoot.path) (\(error.localizedDescription)); nothing in it was removed"
                    )
                }
            } else {
                for directory in [plan.logsDirectory, plan.stateDirectory] where fm.fileExists(atPath: directory.path) {
                    try attempt("delete \(directory.lastPathComponent)", &report) { try fm.removeItem(at: directory) }
                }
                report.completed.append("removed config, logs and state")
            }
            (ensureDirs ?? { Paths.ensureSupportDirectories() })()
        }

        // 5. Tokens last: once the files are gone a surviving token is the
        //    only way back in, and a locked Keychain must not hide that.
        if plan.scope.includesConfig {
            do {
                let removed = try KeychainTokenStore.deleteAll()
                report.completed.append(
                    removed.isEmpty ? "no stored tokens found" : "removed \(removed.count) keychain token(s)")
            } catch {
                Log.warn("reset", "keychain wipe failed: \(error.localizedDescription)")
                report.leftBehind.append(
                    "the Keychain could not be wiped (\(error.localizedDescription)); remove the tokens with `kinhin auth clear`"
                )
            }
        }
        if report.isComplete {
            Log.info("reset", "kinhin was reset (scope: \(plan.scope.rawValue)) — this cannot be undone")
        } else {
            Log.warn(
                "reset",
                "kinhin was reset (scope: \(plan.scope.rawValue)) but \(report.leftBehind.count) item(s) were left behind"
            )
        }
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
