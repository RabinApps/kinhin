import Foundation
import KinhinKit
import Observation

/// State behind the Fleet tab: reads the latest fleet status and the in-flight
/// action from `FleetController` (the single source of truth); its buttons
/// call the controller directly.
@MainActor
@Observable
final class FleetModel {
    /// Set by the window: Start with nothing configured, and the two sheets.
    @ObservationIgnored var onNeedsSetup: () -> Void = {}
    @ObservationIgnored var onShowLogs: () -> Void = {}
    @ObservationIgnored var onShowDiagnostics: () -> Void = {}
    @ObservationIgnored var onShowPipeline: (String) -> Void = { _ in }
    @ObservationIgnored var onShowWorkflowTest: () -> Void = {}
    @ObservationIgnored var onShowVideos: () -> Void = {}
    /// Opens Advanced → Benchmarks (the Fleet tab's benchmark card).
    @ObservationIgnored var onShowBenchmarks: () -> Void = {}
    /// One line about the last benchmark ("Last run 2 hours ago: …"); nil until a report exists.
    var benchmarkSummary: String?

    /// Requeue the queued jobs in the fleet (per forge). Falls back to a
    /// fleet-wide action on the forge when the scope is org-only.
    func requeueQueuedJobs(for forge: ForgeID) {
        guard !isBusy else { return }
        controller.userRequeueQueuedJobs(for: forge)
    }

    /// Mark the queued jobs in the fleet as skipped (per forge). Same
    /// fallback as `requeueQueuedJobs`.
    func skipQueuedJobs(for forge: ForgeID) {
        guard !isBusy else { return }
        controller.userSkipQueuedJobs(for: forge)
    }

    /// Requeue/skip both target a single forge; for org scope the faucet is
    /// fleet-wide, so widen the request to every attached forge.
    func requeueQueuedJobs(for forge: ForgeID, forAll: Bool) {
        if forAll {
            for attached in Set(attachedForges.flatMap(\.values).map(\.id)) {
                requeueQueuedJobs(for: attached)
            }
            return
        }
        requeueQueuedJobs(for: forge)
    }

    func skipQueuedJobs(for forge: ForgeID, forAll: Bool) {
        if forAll {
            for attached in Set(attachedForges.flatMap(\.values).map(\.id)) {
                skipQueuedJobs(for: attached)
            }
            return
        }
        skipQueuedJobs(for: forge)
    }

    @ObservationIgnored let controller: FleetController

    /// Attached forge accounts while this app owns an in-process engine.
    /// A daemon does not currently expose its forge list over RPC.
    var attachedForges: [[String: Forge]] {
        controller.engine?.forges.map { [$0.key: $0.value] } ?? []
    }

    #if DEBUG
        /// The forges a `KINHIN_DEMO` script queues work on; nil outside demo mode. The demo has no live `Forge`
        /// clients, so the Fleet tab lists these instead of `attachedForges`.
        var demoForges: [String]? { (controller.service as? DemoFleetServing)?.forgeNames }
    #endif

    init(controller: FleetController) {
        self.controller = controller
    }

    /// Nil until the first poll (or when setup isn't finished).
    var status: FleetStatus? { controller.status }

    /// A start/stop command in flight (from a button, the menu, or an App
    /// Intent): its button shows a progress indicator and the fleet controls
    /// disable until the command and its status refresh complete.
    var pendingAction: FleetAction? { controller.pendingFleetAction }
    var isBusy: Bool { controls.isBusy }

    /// Start / Stop / Pause / Resume: visibility, titles and busy-disable, shared with the status-bar menu.
    var controls: FleetControls { controller.controls }
    /// The state chip, counters and problem lines, shared with the status-bar menu.
    var presenter: FleetStatusPresenter { controller.statusPresenter }

    var statusLine: String { controller.statusLine }
    /// The runtime/instance diagram at the top of the tab, derived from the
    /// same snapshot the status line renders (one renderer, two surfaces).
    var diagram: FleetDiagramModel { FleetDiagramModel(status: status) }
    /// The diagram's headline before the first status arrives: the status
    /// line's state row, so both cards say the same thing ("Checking the
    /// fleet…", "Needs setup — …", "Fleet not responding — …").
    var diagramPlaceholder: String? {
        guard status == nil else { return nil }
        if presenter.state == .unreachable {
            return String(
                localized: "Fleet not responding — check the daemon in Settings → Daemon.", bundle: .l10n,
                comment: "Runtimes card text when the fleet cannot be reached")
        }
        return String(statusLine.split(separator: "\n").first ?? "")
    }
    /// Set while a per-project image bakes (jobs use the base image meanwhile).
    /// Informational, not an error.
    var imageNotice: String? { status?.imageNotice }
    /// Session-scoped disk-pressure warning the user can dismiss from the Fleet tab.
    var diskPressureNotice: String? { status?.diskPressureNotice }
    var running: Bool { status?.running ?? false }
    var paused: Bool { status?.paused ?? false }
    /// Non-nil while the fleet is paused with auto-resume on: shown on the
    /// Fleet tab so a deliberate pause (e.g. a pause-first delete from
    /// Shortcuts) doesn't read as stuck. Names the poll cadence when the
    /// status carries it; older daemons get the timeless wording.
    var pausedAutoResumeNote: String? {
        guard paused, let autoResume = status?.autoResume, autoResume else { return nil }
        if let cadence = status?.autoResumeCadence {
            return String(
                localized: "Auto-resume is on — the engine \(cadence).", bundle: .l10n,
                comment: "Fleet tab note; %@ is a clause describing the engine's poll cadence")
        }
        return String(
            localized: "Auto-resume is on — the fleet releases itself when the queue is empty.", bundle: .l10n,
            comment: "Fleet tab note shown while paused with auto-resume on")
    }
    var pauseTitle: String { controls.title(.pauseResume) }
    var records: [VMRecord] { status?.records ?? [] }

    /// Any app-side failure (launch, config push) and any stale-daemon
    /// LaunchAgent warning, rendered as a compact footer under the Fleet
    /// tab's status line with distinct styling.
    var fleetStatusFooter: [StatusLine] { presenter.banners }

    // MARK: - Header, banners and status block

    /// The header's state chip ("Running", "Stopping…") and its tone.
    var stateChip: (text: String, tone: Chip.Tone) { (presenter.stateWord, Chip.Tone(presenter.stateStyle)) }

    /// The page-top banners, in the design's order: disk pressure (dismissible), then launch/config-push problems,
    /// then the stale-daemon warning.
    struct BannerRow: Identifiable, Equatable {
        enum Kind: Equatable { case diskPressure, problem, staleDaemon }
        let kind: Kind
        let text: String
        var id: String { "\(kind)-\(text)" }
        var banner: Banner.Kind { kind == .problem ? .error : .warn }
    }

    var bannerRows: [BannerRow] {
        var rows: [BannerRow] = []
        if presenter.state == .unreachable { rows.append(BannerRow(kind: .problem, text: presenter.headline)) }
        if let notice = diskPressureNotice { rows.append(BannerRow(kind: .diskPressure, text: notice)) }
        rows += presenter.problems.map { BannerRow(kind: .problem, text: $0) }
        if let stale = presenter.staleDaemon { rows.append(BannerRow(kind: .staleDaemon, text: stale)) }
        return rows
    }

    /// The status block's lines, headline first: "Queue 3 · Desired 4 · Cap 6 · 8 job slots", then queue age, host
    /// load, rate-limit warning and the per-repo queued/running lines. At most five; empty until a status exists.
    /// The auto-resume line is `pausedAutoResumeNote`, shown above the block.
    var statusLines: [String] {
        guard let status else { return [] }
        let detail = presenter.detailLines.filter { !$0.hasPrefix("⏳") }
        return Array(([Self.headline(for: status)] + detail).prefix(5))
    }

    /// Whether the status block (a card) is drawn: only once the fleet has answered and is running or paused.
    var showsStatusBlock: Bool { status?.running == true && !statusLines.isEmpty }

    /// The placeholder card text for a stopped fleet (the design's "Fleet is stopped…").
    var stoppedNote: String? {
        guard status?.running == false, presenter.state == .stopped else { return nil }
        return String(
            localized: "Fleet is stopped. Start it to pick up queued jobs.", bundle: .l10n,
            comment: "Fleet page note while the fleet is stopped")
    }

    /// The needs-setup text, and the in-flight stopping/starting note.
    var pageNote: String? {
        switch presenter.state {
        case .needsSetup:
            return String(
                localized: "Needs setup — finish the first-run wizard to connect a forge and choose where jobs run.",
                bundle: .l10n, comment: "Fleet page note while first-run setup is unfinished")
        case .stopping:
            return String(
                localized: "Stopping the fleet… (controls disabled)", bundle: .l10n,
                comment: "Fleet page note while a stop command runs")
        case .starting:
            return String(
                localized: "Starting the fleet… (controls disabled)", bundle: .l10n,
                comment: "Fleet page note while a start command runs")
        default: return stoppedNote
        }
    }

    /// True when the page shows only `pageNote` (no runtimes or jobs yet): needs setup, in-flight start/stop.
    var showsOnlyNote: Bool {
        [.needsSetup, .stopping, .starting].contains(presenter.state)
    }

    static func headline(for status: FleetStatus) -> String {
        let base = String(
            localized: "Queue \(status.queueDepth) · Desired \(status.desired) · Cap \(status.capacityCap)",
            bundle: .l10n, comment: "Fleet status headline: queued jobs, desired and maximum VMs")
        guard status.jobCapacity > 0 else { return base }
        return String(
            localized: "\(base) · \(status.jobCapacity) job slots", bundle: .l10n,
            comment: "Fleet status headline; the base counters, then the concurrent job slots")
    }

    // MARK: - Queued work

    /// One forge the Requeue/Skip actions can target.
    struct ForgeRow: Identifiable, Equatable {
        let id: Int
        let label: String
        let forge: ForgeID
        /// The scope covers an organization, so the action widens to every attached forge.
        let widens: Bool
        /// A KINHIN_DEMO row: the buttons do nothing.
        var isDemo = false
    }

    var forgeRows: [ForgeRow] {
        #if DEBUG
            if let names = demoForges {
                return names.enumerated().map {
                    ForgeRow(id: $0.offset, label: $0.element, forge: .github, widens: false, isDemo: true)
                }
            }
        #endif
        return attachedForges.enumerated().compactMap { index, entry in
            guard let key = entry.keys.sorted().first, let forge = entry[key] else { return nil }
            return ForgeRow(id: index, label: key, forge: forge.id, widens: forge.attributesByRepo)
        }
    }

    /// A daemon does not expose its forge list over RPC, so the queued card shows counts only.
    var isDaemonMode: Bool {
        guard forgeRows.isEmpty, let backend = controller.service as? FleetBackend else { return false }
        if case .daemon = backend { return true }
        return false
    }

    /// "3 queued · acme/api ×2, acme/web ×1": the queue depth and its per-repo split.
    var queueSummary: String {
        let depth = status?.queueDepth ?? 0
        let count = String(
            localized: "\(depth) queued", bundle: .l10n, comment: "Queued work count: number of jobs waiting")
        guard let byRepo = status?.queueByRepo, depth > 0, !byRepo.isEmpty else { return count }
        return "\(count) · \(FleetStatusFormatter.repoBreakdown(byRepo))"
    }

    func requeue(_ row: ForgeRow) {
        guard !row.isDemo else { return }
        requeueQueuedJobs(for: row.forge, forAll: row.widens)
    }

    func skip(_ row: ForgeRow) {
        guard !row.isDemo else { return }
        skipQueuedJobs(for: row.forge, forAll: row.widens)
    }

    /// A short, at-a-glance fleet mode label for the Fleet tab header badge.
    /// Nil when no backend is attached (setup unfinished, or before the first poll).
    var fleetModeBadge: String? { controller.fleetMode }
    /// One running job on a VM: a multi-runner VM contributes a row per busy runner.
    struct JobRow: Identifiable, Equatable {
        let vmID: String
        let runner: String
        let job: String
        let repo: String?
        let phase: VMPhase
        let showsRunner: Bool
        var id: String { "\(vmID)#\(runner)" }
    }

    /// The jobs currently running, one row per busy runner.
    var working: [JobRow] {
        records.flatMap { record in
            let stamps = FleetStatusFormatter.runningJobs(of: record)
            return stamps.map {
                JobRow(
                    vmID: record.id, runner: $0.runner, job: $0.job, repo: $0.repo, phase: record.phase,
                    showsRunner: $0.runner != record.id)
            }
        }
    }

    /// Button entry points. A second click while busy is a no-op (the
    /// buttons disable too — this is the state-level backstop).
    func startClicked() {
        guard !isBusy else { return }
        controller.userStart(openSetup: onNeedsSetup)
    }

    func stopClicked() {
        guard !isBusy else { return }
        controller.userStop()
    }

    func togglePause() {
        guard !isBusy else { return }
        controller.userSetPaused(!paused)
    }

    /// Whether a VM has a pipeline to open: only while it holds a job.
    /// The rule itself lives with the diagram, so its rows and the
    /// pipeline sheet can never disagree.
    func hasPipeline(_ record: VMRecord) -> Bool { FleetDiagramModel.opensPipeline(record) }

    func pipelineClicked(_ id: String) {
        onShowPipeline(id)
    }

    func workflowTestClicked() {
        onShowWorkflowTest()
    }

    func deleteClicked(_ id: String) {
        controller.userDeleteVM(id: id)
    }

    /// Hides the disk-pressure banner for this session ("not now"): the
    /// controller keeps it hidden while the same pressure episode persists.
    func dismissDiskPressureNotice() {
        controller.clearDiskPressureNotice()
    }

    // MARK: - Row text

    /// "build — acme/web": the job, then its repository (just the job when the repo is unknown).
    func jobTitle(for row: JobRow) -> String {
        guard let repo = row.repo, !repo.isEmpty else { return row.job }
        return String(
            localized: "\(row.job) — \(repo)", bundle: .l10n, comment: "Current jobs row title: job, then repository")
    }

    /// "vm-b1 · runner 1 · busy": where the job runs and the VM's phase.
    func jobLocation(for row: JobRow) -> String {
        let place = row.showsRunner ? "\(row.vmID) · \(row.runner)" : row.vmID
        return "\(place) · \(row.phase.rawValue)"
    }

    func jobLine(for row: JobRow) -> String {
        let repoText = row.repo ?? ""
        let location = row.showsRunner ? row.runner : row.vmID
        return String(
            localized: "▸ \(row.job) — \(repoText)  (\(location), \(row.phase.rawValue))", bundle: .l10n,
            comment: "Fleet tab job row: job, repository, then runner (or VM id) and phase")
    }
}
