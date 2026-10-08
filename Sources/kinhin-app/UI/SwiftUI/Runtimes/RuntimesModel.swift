import Foundation
import KinhinKit
import Observation

/// State and actions behind Advanced → Routing: the fleet's runtime pools,
/// capacity budget, per-repo routes, and labels — with light editing (add and
/// remove routes, budget sliders, label fields).
///
/// Read state comes from `RuntimesPaneViewModel` (KinhinKit, two-pass: cards
/// render immediately, then live probe results flip the chips in place).
/// Every write goes through the validated config editors
/// (`RuntimesConfigEditor`, `LabelsConfigEditor`, `ConfigEditor`), so the
/// engine gates the result and comments elsewhere in the file survive.
@MainActor
@Observable
final class RuntimesModel: ConfigFormModel {
    typealias Line = StatusLine

    // MARK: - Injectable seams (kept from the AppKit pane)

    /// The config file this pane reads and edits (tests point it at a scratch file).
    @ObservationIgnored var configURL: URL = Paths.config
    /// Fired after any successful config write.
    @ObservationIgnored var onChanged: (() -> Void)?
    /// Where routing problems and "nothing to do" explanations are shown.
    @ObservationIgnored var presentNotice: (_ title: String, _ message: String) -> Void = { title, message in
        AlertKit.notice(title, message)
    }
    /// Host facts the budget previews partition (tests pin them so cap
    /// assertions are exact instead of machine-dependent).
    @ObservationIgnored var hostSnapshot: () -> HostResources = { ResourceProbe().snapshot() }

    // MARK: - Read state

    private(set) var viewModel: RuntimesPaneViewModel?
    private(set) var repo = ""
    private(set) var loads = 0
    private(set) var emptyMessage = ""
    private(set) var loadFailed = false

    var hasLoadedForTesting: Bool { viewModel != nil }

    /// One pool card's text, split for display.
    struct PoolDisplay: Identifiable {
        let id: String
        let title: String
        let detail: String
        let health: RuntimeHealth?
        let isDefault: Bool
    }

    // MARK: - Editing state

    /// The routing section currently on disk (baseline for every edit).
    @ObservationIgnored var currentRuntimeConfig: KinhinConfig.RuntimeConfig?
    @ObservationIgnored private(set) var parsedConfig: KinhinConfig?
    @ObservationIgnored var previewCommitTask: Task<Void, Never>?
    /// The split a drag started from; every tick rescales from it.
    @ObservationIgnored var dragBaseline: [String: Double]?
    /// The latest previewed split, written on release (or after the debounce).
    @ObservationIgnored var pendingBudget: [String: Double]?
    /// True between a slider press and release; reloads wait for the release.
    @ObservationIgnored var isDraggingBudget = false
    @ObservationIgnored var reloadDeferredDuringDrag = false

    /// Pools whose share the other sliders must not touch (session only —
    /// the lock is a UI aid, not config).
    var lockedRuntimes: Set<RuntimeID> = []
    /// One line under the share rows ("Capped at 40% — tart is locked").
    var budgetNotice = ""

    /// Live budget-preview state, updated on every slider tick.
    var capPreviews: [RuntimeID: Int] = [:]
    var percentShares: [String: Double] = [:]
    var starvedRoutes: [String] = []
    /// One row per pool for the Budget card, rebuilt on every tick.
    var budgetRows: [BudgetRow] = []

    /// What one pool's slice of the split looks like right now: the share
    /// (rows always total 100%), the instance cap the engine would enforce
    /// (nil reads "n/a" — no split configured, or a host pool outside the
    /// partition), and whether the pool takes unmatched jobs.
    struct BudgetRow: Identifiable {
        let id: RuntimeID
        let share: Double
        let cap: Int?
        let isDefault: Bool
    }

    // MARK: - Label fields

    /// What the label fields show. Settable by the view while the user
    /// types; committed through `commitLabels` on Enter or focus loss.
    var fleetLabelsText = ""
    var containerLabelsText = ""
    var labelsStatus = Line(text: "")
    var showsContainerLabels: Bool { viewModel?.containerConfigured == true }

    // MARK: - Loading

    /// Two-pass load: cards render immediately (health marked "checking…"),
    /// then live probe results flip the chips in place — the pane never
    /// blocks on a subprocess.
    func reload() {
        // A reload mid-drag would rebuild the rows under the user's hand.
        guard !isDraggingBudget else {
            reloadDeferredDuringDrag = true
            return
        }
        loads += 1
        Task { await reloadWithHealth() }
    }

    /// True while a reload's two passes are in flight; tests wait for this
    /// to clear before asserting preview state.
    private(set) var isProbingHealth = false
    /// A reload was requested while one was already probing. It re-runs when
    /// the in-flight pass finishes — dropping it would hide a change the
    /// user just wrote (e.g. a route added mid-probe).
    private var reloadRequestedWhileProbing = false

    func reloadWithHealth() async {
        guard !isProbingHealth else {
            reloadRequestedWhileProbing = true
            return
        }
        isProbingHealth = true
        defer {
            isProbingHealth = false
            if reloadRequestedWhileProbing {
                reloadRequestedWhileProbing = false
                reload()
            }
        }
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            loadFailed = true
            emptyMessage = "No config file yet — finish the Setup tab first."
            return
        }
        let yaml: String
        let parsed: KinhinConfig
        do {
            yaml = try ConfigStore.text(at: configURL)
            parsed = try ConfigLoader.parse(yaml)
        } catch {
            loadFailed = true
            emptyMessage = "config.yaml has a problem — \(error.localizedDescription). Fix it with Edit YAML…"
            return
        }
        loadFailed = false
        let host = ResourceProbe().snapshot()

        // Fast pass: no probes.
        let fast = await RuntimesPaneViewModel.load(configYAML: yaml, host: host, reserve: parsed.reserve)
        viewModel = fast
        parsedConfig = parsed
        repo = parsed.repo
        do {
            currentRuntimeConfig = try RuntimesConfigEditor.parsed(from: yaml)
        } catch {
            // The config parses but the runtime section does not: surface it
            // instead of silently editing against default-shaped values.
            loadFailed = true
            emptyMessage = "runtimes section has a problem — \(error.localizedDescription)"
            return
        }
        refreshLabelFields()
        refreshBudgetPreviews(budget: currentRuntimeConfig?.budget ?? [:])

        // Health pass: probe each enabled pool's runtime concurrently.
        let withHealth = await RuntimesPaneViewModel.load(
            configYAML: yaml, host: host, reserve: parsed.reserve, loadHealth: true)
        guard withHealth != fast else { return }  // nothing changed; no flicker
        viewModel = withHealth
        refreshBudgetPreviews(budget: currentRuntimeConfig?.budget ?? [:])
    }

    // MARK: - Pool display

    var poolRows: [PoolDisplay] {
        guard let vm = viewModel else { return [] }
        return vm.pools.map { pool in
            let name: String
            switch pool.runtime {
            case .tart: name = "🍎 Tart VMs (macOS)"
            case .appleContainer: name = "🐧 Apple containers (Linux)"
            case .docker: name = "🐳 Docker (Linux)"
            case .host: name = "Host (this Mac)"
            }
            var title = name + " — "
            if let cap = pool.cap {
                title += "cap \(cap) instance\(cap == 1 ? "" : "s")"
            } else {
                title += "cap n/a"
            }
            // The Budget card owns the share display now — no duplicate
            // "N% of host budget" buried in pool titles.
            if pool.runtime == vm.defaultRuntime {
                title += " · default"
            }
            var details = ["labels: " + pool.labels.joined(separator: ", ")]
            if let note = RuntimesPaneViewModel.healthNote(for: pool.health) {
                details.append("⚠︎ " + note)
            }
            return PoolDisplay(
                id: pool.runtime.rawValue, title: title, detail: details.joined(separator: "\n"),
                health: pool.health, isDefault: pool.runtime == vm.defaultRuntime)
        }
    }

    var routeRows: [(pattern: String, title: String)] {
        guard let vm = viewModel else { return [] }
        return vm.routes.map { route in
            var title =
                route.isWorkflow
                ? "\(route.pattern)  →  \(route.runtime.rawValue)  (workflow)"
                : "\(route.pattern)  →  \(route.runtime.rawValue)"
            if route.runtime == .host { title += "  ⚠︎ unisolated" }
            return (route.pattern, title)
        }
    }

    var headline: String {
        guard let vm = viewModel else { return "" }
        return "Fleet scope: \(repo) — \(vm.routingConfigured ? "routed" : "single-pool") fleet"
    }

    /// Whether the budget card applies: only when the fleet is partitioned.
    var showsBudget: Bool { (viewModel?.pools.count ?? 0) > 1 && currentRuntimeConfig != nil }

    var budgetRuntimeIDs: [RuntimeID] {
        viewModel?.pools.map(\.runtime) ?? []
    }

    var defaultRuntimeID: RuntimeID {
        RuntimeID(rawValue: currentRuntimeConfig?.defaultRuntime ?? "") ?? .tart
    }

    /// One pool's share as the slider should show it: the default's share
    /// is derived (the engine ignores its stored weight and computes the
    /// remainder), so a hand-edited `budget:` line can never park the
    /// slider where the fleet won't actually run.
    func budgetShare(for runtime: RuntimeID) -> Double {
        guard let rc = currentRuntimeConfig else { return 0 }
        return BudgetEditor.displayShares(current: rc.budget, defaultRuntime: defaultRuntimeID)[runtime.rawValue] ?? 0
    }

    // MARK: - Sheets (Add Route / Edit YAML)

    // Settable from the sheet-lifecycle extensions (RuntimesModel+Routes,
    // RuntimesModel+YAML); the views only read them or bind for presentation.

    /// The open Add Route sheet's offer: which runtimes the route may target.
    /// `RuntimesView` presents `AddRouteSheet` while this is non-nil.
    var routeOffer: RouteOffer?
    /// A problem with the pending sheet values (Add Route or Edit YAML,
    /// which are never open at once), shown inside the sheet.
    var sheetProblem = ""
    /// Whether the Edit YAML sheet is open.
    var isYAMLEditorOpen = false
    /// The config's exact on-disk bytes, captured when the YAML editor opened.
    var yamlAtOpen = ""

    // MARK: - Errors

    func presentError(_ error: Error) {
        AlertKit.present(error: error, title: "Couldn't update the routing config")
    }

    // MARK: - Display helpers (shared with tests)

    /// A small colored health chip: green ready / red not ready /
    /// grey "checking…" while the probe pass is in flight.
    static func healthChip(_ health: RuntimeHealth?, probing: Bool) -> (text: String, style: StatusStyle) {
        switch health {
        case .ready:
            return ("● ready", .ok)
        case .missing(let tool, _):
            return ("● \(tool) missing", .error)
        case .broken:
            return ("● error", .error)
        case nil:
            return (probing ? "● checking…" : "", .secondary)
        }
    }
}
