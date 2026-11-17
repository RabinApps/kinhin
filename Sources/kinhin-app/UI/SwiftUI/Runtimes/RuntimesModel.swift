import Foundation
import KinhinKit
import Observation

/// State and actions behind the Runtimes page: the fleet's runtime pools,
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

    /// There is no config.yaml at all yet (as opposed to one that does not load): the page has nothing to edit.
    var configMissing: Bool { !FileManager.default.fileExists(atPath: configURL.path) }

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
            emptyMessage = String(
                localized: "No config file yet — finish setup first.", bundle: .l10n,
                comment: "Routing tab empty state")
            return
        }
        let yaml: String
        let parsed: KinhinConfig
        do {
            yaml = try ConfigStore.text(at: configURL)
            parsed = try ConfigLoader.parse(yaml)
        } catch {
            loadFailed = true
            emptyMessage = String(
                localized: "config.yaml has a problem — \(error.localizedDescription). Fix it with Edit YAML…",
                bundle: .l10n, comment: "Routing tab empty state; %@ is the parse error")
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
            emptyMessage = String(
                localized: "runtimes section has a problem — \(error.localizedDescription)", bundle: .l10n,
                comment: "Routing tab empty state; %@ is the parse error")
            return
        }
        refreshLabelFields()
        refreshBudgetPreviews(budget: currentRuntimeConfig?.budget ?? [:])
        // The pool images are listed alongside the health pass and applied whenever the CLI answers, so a slow
        // listing never holds back the health results or a coalesced reload. Each listing lists this reload's
        // config; a newer reload's listing supersedes it.
        containerPoolImageGeneration += 1
        let generation = containerPoolImageGeneration
        containerPoolImageListing = Task {
            await self.refreshContainerPoolImages(container: parsed.container, generation: generation)
        }

        // Health pass: probe each enabled pool's runtime concurrently.
        let withHealth = await RuntimesPaneViewModel.load(
            configYAML: yaml, host: host, reserve: parsed.reserve, loadHealth: true)
        guard withHealth != fast else { return }  // nothing changed; no flicker
        viewModel = withHealth
        refreshBudgetPreviews(budget: currentRuntimeConfig?.budget ?? [:])
    }

    // MARK: - Routes

    /// One route row: the pattern, the runtime it goes to, and whether it names one workflow.
    struct RouteDisplay: Identifiable, Equatable {
        let pattern: String
        let runtime: RuntimeID
        let isWorkflow: Bool
        var id: String { pattern }
    }

    var routeRows: [RouteDisplay] {
        (viewModel?.routes ?? []).map {
            RouteDisplay(pattern: $0.pattern, runtime: $0.runtime, isWorkflow: $0.isWorkflow)
        }
    }

    /// Whether the budget card applies: only when the fleet is partitioned.
    var showsBudget: Bool { (viewModel?.pools.count ?? 0) > 1 && currentRuntimeConfig != nil }

    var budgetRuntimeIDs: [RuntimeID] {
        viewModel?.pools.map(\.runtime) ?? []
    }

    var defaultRuntimeID: RuntimeID {
        currentRuntimeConfig?.defaultRuntime ?? .tart
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
    /// `RuntimesPage` presents `AddRouteSheet` while this is non-nil.
    var routeOffer: RouteOffer?
    /// A problem with the pending sheet values (Add Route or Edit YAML,
    /// which are never open at once), shown inside the sheet.
    var sheetProblem = ""
    /// Whether the Edit YAML sheet is open.
    var isYAMLEditorOpen = false
    /// The config's exact on-disk bytes, captured when the YAML editor opened.
    var yamlAtOpen = ""
    /// The open container pool sheet (add or edit). `RuntimesPage` presents `ContainerPoolSheet` while non-nil.
    var containerPoolOffer: ContainerPoolOffer?

    // MARK: - Container pools

    /// Whether each named container pool's image is built, by image name, as of the last listing; nil until the
    /// images were listed, or when the listing failed (the cards then say nothing rather than call every pool
    /// unbuilt). Keyed by image, so a pool added, renamed or pointed at another image since the listing shows no
    /// chip until the next one answers, instead of an earlier pool's answer.
    var builtContainerImages: [String: Bool]?
    /// The image listing the last reload started (tests await it), and the number of the newest one: an answer from
    /// an older listing is dropped, so it cannot overwrite a newer reload's.
    @ObservationIgnored var containerPoolImageListing: Task<Void, Never>?
    @ObservationIgnored var containerPoolImageGeneration = 0
    /// The local Apple container image names (tests inject a listing). Throws when the CLI cannot list them.
    @ObservationIgnored var listContainerImages: () async throws -> [String] = {
        try await AppleContainerRuntime().listedImageNames()
    }
    /// Confirms removing a container pool. Real UI shows an alert; tests answer for it.
    @ObservationIgnored var confirmRemoval: (_ title: String, _ message: String, _ button: String) -> Bool = {
        title, message, button in
        AlertKit.confirm(title: title, message: message, confirmTitle: button, destructive: true)
    }

    // MARK: - Errors

    func presentError(_ error: Error) {
        AlertKit.present(
            error: error,
            title: String(localized: "Couldn't update the routing config", bundle: .l10n, comment: "Alert title"))
    }

    // MARK: - Display helpers (shared with tests)

    /// The health chip's text and tone: green ready / red not ready /
    /// grey "checking…" while the probe pass is in flight.
    static func healthChip(_ health: RuntimeHealth?, probing: Bool) -> (text: String, style: StatusStyle) {
        switch health {
        case .ready:
            return (String(localized: "ready", bundle: .l10n, comment: "Runtime health chip"), .ok)
        case .missing(let tool, _):
            return (
                String(
                    localized: "\(tool) missing", bundle: .l10n,
                    comment: "Runtime health chip; %@ is the missing tool"), .error
            )
        case .broken:
            return (String(localized: "error", bundle: .l10n, comment: "Runtime health chip"), .error)
        case nil:
            return (
                probing ? String(localized: "checking…", bundle: .l10n, comment: "Runtime health chip") : "",
                .secondary
            )
        }
    }
}
