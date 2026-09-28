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
final class RuntimesModel {
    typealias Line = StatusLine

    // MARK: Injectable seams (kept from the AppKit pane)

    /// The config file this pane reads and edits (tests point it at a scratch file).
    @ObservationIgnored var configURL: URL = Paths.config
    /// Fired after any successful config write.
    @ObservationIgnored var onEdited: (() -> Void)?
    /// Where routing problems and "nothing to do" explanations are shown.
    @ObservationIgnored var presentNotice: (_ title: String, _ message: String) -> Void = { title, message in
        AlertKit.notice(title, message)
    }
    /// Host facts the budget previews partition (tests pin them so cap
    /// assertions are exact instead of machine-dependent).
    @ObservationIgnored var hostSnapshot: () -> HostResources = { ResourceProbe().snapshot() }

    // MARK: Read state

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

    // MARK: Editing state

    /// The routing section currently on disk (baseline for every edit).
    @ObservationIgnored private(set) var currentRuntimeConfig: KinhinConfig.RuntimeConfig?
    @ObservationIgnored private(set) var parsedConfig: KinhinConfig?
    @ObservationIgnored private var previewCommitTask: Task<Void, Never>?

    /// Live budget-preview state, updated on every slider tick.
    private(set) var capPreviews: [RuntimeID: Int] = [:]
    private(set) var percentShares: [String: Double] = [:]
    private(set) var remainderNote = ""
    private(set) var starvedRoutes: [String] = []

    // MARK: Label fields

    /// What the label fields show. Settable by the view while the user
    /// types; committed through `commitLabels` on Enter or focus loss.
    var fleetLabelsText = ""
    var containerLabelsText = ""
    private(set) var labelsStatus = Line(text: "")
    var showsContainerLabels: Bool { viewModel?.containerConfigured == true }

    // MARK: Loading

    /// Two-pass load: cards render immediately (health marked "checking…"),
    /// then live probe results flip the chips in place — the pane never
    /// blocks on a subprocess.
    func reload() {
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

    // MARK: Pool display

    /// The "On this Mac" rows: what's installed vs not, and whether the
    /// config actually uses it.
    var availabilityRows: [(id: String, title: String, detail: String?)] {
        guard let vm = viewModel else { return [] }
        return [RuntimeID.tart, .appleContainer, .docker].compactMap { id in
            guard let health = vm.availability[id] else { return nil }
            let inUse = vm.pools.contains { $0.runtime == id }
            let title = Self.availabilityTitle(id, health: health, inUse: inUse)
            let detail: String?
            switch health {
            case .ready:
                detail = nil
            case .missing(_, let fix):
                detail = "To install: \(fix)"
            case .broken(let why):
                detail = why
            }
            return (id.rawValue, title, detail)
        }
    }

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
            if let pct = pool.budgetPercent {
                title += String(format: " · %.0f%% of host budget", pct)
            }
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

    func budgetShare(for runtime: RuntimeID) -> Double {
        currentRuntimeConfig?.budget[runtime.rawValue] ?? 0
    }

    // MARK: Budget editing

    /// Slider moved: update the live cap previews on every drag tick, and
    /// debounce the actual config write until the drag settles (~400ms).
    func budgetSliderChanged(runtime: RuntimeID, fraction: Double) {
        guard let rc = currentRuntimeConfig else { return }
        let defaultRuntime = defaultRuntimeID
        let budget = BudgetEditor.setShare(
            of: runtime, to: fraction, current: rc.budget, defaultRuntime: defaultRuntime)
        refreshBudgetPreviews(budget: budget)

        previewCommitTask?.cancel()
        previewCommitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            // refreshPane: false — the on-screen values already match what
            // we're writing; a full rebuild mid-gesture would yank the
            // slider out from under the user's hand.
            self?.commit(budget: budget, defaultRuntime: rc.defaultRuntime, refreshPane: false)
        }
    }

    /// Recompute "N inst" previews, percent labels, and the starved-route
    /// warning from a candidate budget — the same partition math the engine
    /// uses.
    private func refreshBudgetPreviews(budget: [String: Double]) {
        guard let parsed = parsedConfig, let rc = currentRuntimeConfig else { return }
        let def = defaultRuntimeID
        let caps = BudgetEditor.previewCaps(
            host: hostSnapshot(),
            reserve: parsed.reserve,
            vmShape: (parsed.vm.cpuCount, parsed.vm.memoryGB),
            containerShape: parsed.container.map { ($0.cpus, $0.memoryGB) },
            weights: budget,
            defaultRuntime: def,
            dockerShape: parsed.docker.map { ($0.cpus, $0.memoryGB) }
        )
        capPreviews = caps
        // Percent labels update live (they were rendered for the old split).
        var shares: [String: Double] = [:]
        let total = budget.values.reduce(0, +)
        for (runtime, weight) in budget {
            let effective = runtime == def.rawValue ? max(0, 1 - (total - weight)) : weight
            shares[runtime] = effective
        }
        percentShares = shares
        // Starved-route strip: recomputed on every tick so a drag that would
        // strand a route shows the warning before the user lets go. With no
        // budget on disk the fleet isn't partitioned ("cap n/a"), so nothing
        // can be starved yet.
        let configured = Set(viewModel?.pools.map(\.runtime) ?? [])
        starvedRoutes = BudgetEditor.starvedRoutes(
            routes: rc.routes, caps: caps, configuredRuntimes: configured,
            isPartitioned: !(rc.budget.isEmpty && budget.isEmpty))
        let pct = Int(((budget[def.rawValue] ?? 0) * 100).rounded())
        remainderNote = String(format: "%@ keeps the remaining %d%% — %d inst", def.rawValue, pct, caps[def] ?? 0)
    }

    func percentText(for runtime: RuntimeID) -> String {
        let share = percentShares[runtime.rawValue] ?? budgetShare(for: runtime)
        return "\(Int((share * 100).rounded()))%"
    }

    /// Default switched: rewrite the section with the new default (weights
    /// stay; the remainder rule re-homes).
    func defaultRuntimeChanged(to rawValue: String) {
        guard let rc = currentRuntimeConfig else { return }
        commit(budget: rc.budget, defaultRuntime: rawValue)
    }

    func commit(budget: [String: Double], defaultRuntime: String, refreshPane: Bool = true) {
        guard var rc = currentRuntimeConfig else { return }
        if let problem = BudgetEditor.validate(budget) {
            presentError(NSError(domain: "kinhin", code: 2, userInfo: [NSLocalizedDescriptionKey: problem]))
            reload()  // snap sliders back to the on-disk truth
            return
        }
        rc.budget = budget
        rc.defaultRuntime = defaultRuntime
        do {
            try RuntimesConfigEditor.apply(rc, to: configURL)
            currentRuntimeConfig = rc  // next drag starts from the new baseline
            if refreshPane { reload() }
            onEdited?()
        } catch {
            presentError(error)
            reload()
        }
    }

    // MARK: Labels

    private func refreshLabelFields() {
        let yaml = ConfigStore.textOrLog(at: configURL)
        do {
            fleetLabelsText = try LabelsConfigEditor.labels(in: yaml, scope: .fleet).joined(separator: ", ")
            containerLabelsText = try LabelsConfigEditor.labels(in: yaml, scope: .container).joined(separator: ", ")
        } catch {
            // Leave the fields as they were and say why they are not current.
            Log.warn("runtimes-pane", "could not read labels: \(error.localizedDescription)")
            labelsStatus = Line(text: "Labels not loaded — \(error.localizedDescription)", style: .error)
        }
    }

    /// Restores one label field from disk after a failed commit (the other
    /// field may hold the user's own edit, so it is left alone).
    private func snapBackLabelField(_ scope: LabelsConfigEditor.Scope) {
        let yaml = ConfigStore.textOrLog(at: configURL)
        do {
            let labels = try LabelsConfigEditor.labels(in: yaml, scope: scope).joined(separator: ", ")
            if scope == .fleet {
                fleetLabelsText = labels
            } else {
                containerLabelsText = labels
            }
        } catch {
            Log.warn("runtimes-pane", "could not re-read labels: \(error.localizedDescription)")
        }
    }

    /// Commit a label field edit (called on Enter or focus loss).
    func commitLabels(scope: LabelsConfigEditor.Scope, text: String) {
        let labels = Self.parseLabelList(text)
        do {
            try LabelsConfigEditor.apply(labels, scope: scope, to: configURL)
            Log.info("runtimes-pane", "\(scope == .fleet ? "fleet" : "container") labels updated")
            labelsStatus = Line(text: "")
            onEdited?()
        } catch {
            presentError(error)
            // Snap the field back to the on-disk truth.
            snapBackLabelField(scope)
        }
    }

    /// Parse a comma-separated label list.
    static func parseLabelList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Sheets (Add Route / Edit YAML)

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

    // MARK: Errors

    func presentError(_ error: Error) {
        AlertKit.present(error: error, title: "Couldn't update the routing config")
    }

    // MARK: Display helpers (shared with tests)

    /// "On this Mac" row title: what's installed vs not, and whether the
    /// config actually uses it.
    static func availabilityTitle(_ id: RuntimeID, health: RuntimeHealth, inUse: Bool) -> String {
        let name: String
        switch id {
        case .tart: name = "🍎 Tart (macOS VMs)"
        case .appleContainer: name = "🐧 Apple container (Linux)"
        case .docker: name = "🐳 Docker (Linux)"
        case .host: name = "Host"
        }
        let state: String
        switch health {
        case .ready: state = "installed ✓"
        case .missing: state = "not installed"
        case .broken: state = "installed — needs attention"
        }
        return "\(name) — \(state)\(inUse ? " · used by your fleet" : " · not used by your config")"
    }

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
