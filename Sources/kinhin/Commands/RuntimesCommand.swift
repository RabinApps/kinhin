import Foundation
import KinhinKit

/// `kinhin runtimes` — the CLI mirror of the menu bar Runtimes pane: label
/// pools with per-runtime caps, the budget split, live health from each
/// runtime's probe, and the route table.
///
/// Subcommands let scripts edit routes through the same validated path the
/// pane uses (RuntimesConfigEditor — comments preserved, engine validation
/// gates every write) and notify a running daemon to hot-reload:
///
///     kinhin runtimes route add acme/api appleContainer
///     kinhin runtimes route add acme/api docker
///     kinhin runtimes route add "acme/web@Nightly" appleContainer
///     kinhin runtimes route remove acme/api
enum RuntimesCommand {
    static func run(_ args: [String]) async {
        // Subcommand form: `runtimes route add|remove …` (args still carry the
        // `runtimes` head, matching AuthCommand's convention). Bare `runtimes`
        // (with any flags like --json) keeps the read-only summary behavior.
        if let tail = routeTail(args) {
            do {
                try await route(tail)
            } catch let error as RouteError {
                fail(error.errorDescription ?? "runtimes command failed", exit: .usage)
            } catch {
                fail(error)
            }
            return
        }

        let summary: Summary
        do {
            summary = try await loadSummary(noHealth: args.contains("--no-health"))
        } catch let error as RouteError {
            fail(error.errorDescription ?? "runtimes command failed", exit: .config)
        } catch {
            fail(error)
        }
        if args.contains("--json") {
            print(String(decoding: summary.json, as: UTF8.self))
        } else {
            printText(summary.vm, repo: summary.repo, budget: summary.budget)
        }
        // Documented contract: no pools at all (nothing set up yet) is a failing status.
        if summary.vm.pools.isEmpty { exit(CLIExit.general.rawValue) }
    }

    /// Everything `run` prints or emits, and what the MCP `runtimes` tool
    /// returns: the view model plus the already-encoded JSON document.
    struct Summary {
        let vm: RuntimesPaneViewModel
        let json: Data
        let repo: String
        let budget: [String: Double]
    }

    /// The read-only summary, without printing or exiting — shared by
    /// `runtimes` and the MCP `runtimes` tool. Config problems throw
    /// `RouteError` for the caller to classify.
    static func loadSummary(noHealth: Bool) async throws -> Summary {
        guard FileManager.default.fileExists(atPath: Paths.config.path) else {
            throw RouteError.usage("no config at \(Paths.config.path) — run: kinhin config init")
        }
        let yaml: String
        let parsed: KinhinConfig
        do {
            yaml = try String(contentsOf: Paths.config, encoding: .utf8)
            parsed = try ConfigLoader.parse(yaml)
        } catch {
            throw RouteError.usage("config.yaml can't be used — \(error.localizedDescription)")
        }
        let host = ResourceProbe().snapshot()
        let vm = await RuntimesPaneViewModel.load(
            configYAML: yaml,
            host: host,
            reserve: parsed.reserve,
            loadHealth: !noHealth
        )
        return Summary(
            vm: vm,
            json: try CLIJSON.data(jsonPayload(vm: vm, repo: parsed.repo)),
            repo: parsed.repo,
            budget: parsed.runtimes?.budget ?? [:]
        )
    }

    // MARK: - Route editing

    /// The arguments after `runtimes route` when `args` is the route-editing
    /// form, else nil (bare `runtimes` / `runtimes --json …`). Exposed for
    /// tests — `run` exits the process, so the slice must be pinned directly.
    static func routeTail(_ args: [String]) -> [String]? {
        guard args.dropFirst().first == "route" else { return nil }
        return Array(args.dropFirst(2))
    }

    /// The route-editing core. Receives the arguments *after* `runtimes
    /// route` — i.e. `add <pattern> <runtime>` / `remove <pattern>`.
    static func route(_ args: [String], configURL: URL = Paths.config, notifyDaemon: Bool = true) async throws {
        let op = args.first
        guard op == "add" || op == "remove" else {
            throw RouteError.usage(
                "usage: kinhin runtimes route add <owner/repo[@Workflow]> <tart|appleContainer|docker|host> [--consent]\n       kinhin runtimes route remove <owner/repo[@Workflow]>"
            )
        }

        let pattern = args.count > 1 ? args[1].trimmingCharacters(in: .whitespaces) : ""
        guard !pattern.isEmpty else {
            throw RouteError.usage(
                "missing pattern — e.g. owner/repo for a whole repo, or owner/repo@Workflow Name for one workflow")
        }
        if pattern.contains("@"), pattern.hasSuffix("@") || pattern.hasPrefix("@") {
            throw RouteError.usage(
                "workflow routes look like owner/repo@Workflow Name — the '@' cannot be first or last")
        }

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw RouteError.usage("no config at \(configURL.path) — run: kinhin config init")
        }
        let yaml: String
        do {
            yaml = try String(contentsOf: configURL, encoding: .utf8)
        } catch {
            throw RouteError.usage("can't read \(configURL.path) — \(error.localizedDescription)")
        }
        let existing: KinhinConfig.RuntimeConfig?
        do {
            // nil (no section yet) is normal; a throw means the section exists
            // but is malformed.
            existing = try RuntimesConfigEditor.parsed(from: yaml)
        } catch {
            throw RouteError.usage("config.yaml has an invalid runtimes section — fix it, or run: kinhin doctor")
        }
        let hadRouting = existing != nil
        var rc = existing ?? KinhinConfig.RuntimeConfig()

        switch op {
        case "add":
            let runtimeName = args.count > 2 ? args[2] : ""
            guard !runtimeName.isEmpty, let runtime = RuntimeID(rawValue: runtimeName) else {
                throw RouteError.usage(
                    "unknown or missing runtime '\(runtimeName)' — expected 'tart', 'appleContainer', 'docker', or 'host'"
                )
            }
            let consent = args.contains("--consent")
            if runtime == .host {
                guard consent else {
                    throw RouteError.usage(
                        "host routes run repo code directly on your Mac, unisolated. Review the risk, then re-run with --consent"
                    )
                }
            } else if consent {
                throw RouteError.usage("--consent applies to host routes only")
            }
            guard !rc.routes.contains(where: { $0.pattern == pattern }) else {
                throw RouteError.usage(
                    "a route for '\(pattern)' already exists — remove it first: kinhin runtimes route remove \(pattern)"
                )
            }
            rc.routes.append(
                KinhinConfig.RuntimeConfig.Route(
                    pattern: pattern, runtime: runtime, consent: consent ? true : nil))
            if !hadRouting {
                print("note: created the runtimes: section (default: \(rc.defaultRuntime))")
            }
        case "remove":
            guard rc.routes.contains(where: { $0.pattern == pattern }) else {
                throw RouteError.usage("no route for '\(pattern)'")
            }
            rc.routes.removeAll { $0.pattern == pattern }
        default:
            break
        }

        do {
            try RuntimesConfigEditor.apply(rc, to: configURL)
        } catch let error as ConfigEditError {
            throw RouteError.usage(error.errorDescription ?? "config update rejected")
        }

        print(
            op == "add"
                ? "✓ routed \(pattern) → \(rc.routes.last?.runtime.rawValue ?? "")" : "✓ removed route \(pattern)")
        let remaining = rc.routes.count
        print(remaining == 0 ? "  routes: (none — every job uses the default pool)" : "  routes: \(remaining)")

        // A live daemon picks the new route table up without a restart.
        guard notifyDaemon, RPCClient.isDaemonAlive() else { return }
        do {
            try RPCClient().reloadConfig()
            print("  daemon notified — routing reloaded")
        } catch {
            print("  warning: daemon did not accept the reload — \(error.localizedDescription)")
        }
    }

    /// Command failures routed through `fail` at the call site.
    struct RouteError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        static func usage(_ message: String) -> RouteError { RouteError(message: message) }
    }

    // MARK: - Text output

    static func printText(_ vm: RuntimesPaneViewModel, repo: String, budget: [String: Double]) {
        print("kinhin runtimes — scope: \(repo) (\(vm.routingConfigured ? "routed" : "single-pool") fleet)")
        print("")

        print("Pools & capacity")
        for pool in vm.pools {
            let name = pool.runtime == .tart ? "🍎 Tart VMs (macOS)" : "🐧 Apple containers (Linux)"
            var line = "  \(name)"
            line += pool.cap.map { " — cap \($0)" } ?? " — cap n/a"
            if let pct = pool.budgetPercent {
                line += String(format: " · %.0f%% of budget", pct)
            }
            if pool.runtime == vm.defaultRuntime {
                line += " · default"
            }
            print(line)
            print("    labels: \(pool.labels.joined(separator: ", "))")
            if let note = RuntimesPaneViewModel.healthNote(for: pool.health) {
                print("    health: ⚠︎ \(note)")
            } else if pool.health == .ready {
                print("    health: ✓ ready")
            } else {
                print("    health: (unavailable)")
            }
        }
        print("")

        print("Budget")
        let shares = BudgetEditor.displayShares(current: budget, defaultRuntime: vm.defaultRuntime)
        for pool in vm.pools {
            let pct = Int((shares[pool.runtime.rawValue] ?? 0).rounded() * 100)
            let bar =
                String(repeating: "█", count: max(0, pct / 5)) + String(repeating: "░", count: max(0, 20 - pct / 5))
            let marker = pool.runtime == vm.defaultRuntime ? " (default, remainder)" : ""
            print(
                "  \(pool.runtime.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \(bar) \(pct)%\(marker)")
        }
        print("")

        print("Routes")
        if vm.routes.isEmpty {
            print("  (none — every job uses the default pool)")
        } else {
            for route in vm.routes {
                let kind = route.isWorkflow ? "workflow" : "repo"
                print(
                    "  \(route.pattern.padding(toLength: 40, withPad: " ", startingAt: 0)) → \(route.runtime.rawValue)  [\(kind)]"
                )
            }
        }
        print("")
        print("Unmatched jobs → \(vm.defaultRuntime.rawValue)")
    }

    // MARK: - JSON output

    struct PoolJSON: Codable {
        let runtime: String
        let labels: [String]
        let cap: Int?
        let budgetPercent: Double?
        let health: String?
        let healthNote: String?
    }

    struct RouteJSON: Codable {
        let pattern: String
        let runtime: String
        let isWorkflow: Bool
    }

    struct RuntimesJSON: Codable {
        let repo: String
        let routingConfigured: Bool
        let defaultRuntime: String
        let pools: [PoolJSON]
        let routes: [RouteJSON]
        /// The availability sweep: every runtime this Mac could use (configured
        /// or not) and what probing it found — `--no-health` leaves it empty.
        let availability: [String: String]
    }

    static func healthDescription(_ health: RuntimeHealth?) -> String? {
        switch health {
        case nil: return nil
        case .ready: return "ready"
        case .missing(let tool, _): return "missing:\(tool)"
        case .broken(let why): return "broken:\(why)"
        }
    }

    /// The `runtimes --json` document body — building it is shared with
    /// `loadSummary`, which encodes it for both the CLI and the MCP tool.
    static func jsonPayload(vm: RuntimesPaneViewModel, repo: String) -> RuntimesJSON {
        RuntimesJSON(
            repo: repo,
            routingConfigured: vm.routingConfigured,
            defaultRuntime: vm.defaultRuntime.rawValue,
            pools: vm.pools.map { pool in
                PoolJSON(
                    runtime: pool.runtime.rawValue,
                    labels: pool.labels,
                    cap: pool.cap,
                    budgetPercent: pool.budgetPercent,
                    health: healthDescription(pool.health),
                    healthNote: RuntimesPaneViewModel.healthNote(for: pool.health)
                )
            },
            routes: vm.routes.map { route in
                RouteJSON(pattern: route.pattern, runtime: route.runtime.rawValue, isWorkflow: route.isWorkflow)
            },
            availability: vm.availability.reduce(into: [:]) { result, entry in
                result[entry.key.rawValue] = healthDescription(entry.value) ?? "unknown"
            }
        )
    }
}
