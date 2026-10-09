import Foundation
import KinhinKit
import Observation

// MARK: - Backend seam

/// Where a benchmark runs and who pauses the fleet: the daemon or in-process
/// engine behind `FleetServing`, or — with no fleet set up yet — this process.
/// A seam so tests drive the model with no daemon, VM or shell.
protocol BenchmarkRunning: Sendable {
    /// The fleet's load before a run, so the confirmation can say what pausing costs.
    func impact() async throws -> BenchmarkFleetImpact
    func start(_ options: BenchmarkOptions) async throws -> String
    func status(runID: String) async throws -> BenchmarkRunStatus
    func cancel(runID: String) async throws
    /// The most recent run, if one exists (a run another window or the CLI started may still be going).
    func latest() async -> BenchmarkRunStatus?
}

/// The fleet's own backend (the daemon over RPC, or the in-process engine).
struct ServiceBenchmarkRunner: BenchmarkRunning {
    let service: any FleetServing

    func impact() async throws -> BenchmarkFleetImpact {
        BenchmarkFleetImpact(try await service.status(includeUsage: false))
    }

    func start(_ options: BenchmarkOptions) async throws -> String { try await service.benchStart(options) }

    func status(runID: String) async throws -> BenchmarkRunStatus { try await service.benchStatus(runID: runID) }

    func cancel(runID: String) async throws { _ = try await service.benchCancel(runID: runID) }

    func latest() async -> BenchmarkRunStatus? {
        // A daemon that predates benchmarks, or no run yet: nothing to attach to.
        try? await service.benchStatus(runID: nil)
    }
}

/// No fleet yet: nothing to pause, so the run lives in this process.
struct LocalBenchmarkRunner: BenchmarkRunning {
    func impact() async throws -> BenchmarkFleetImpact { BenchmarkFleetImpact() }

    func start(_ options: BenchmarkOptions) async throws -> String {
        let config = try ConfigLoader.load()
        return try BenchmarkRegistry.shared.start(options: options, environment: try .production(config: config))
    }

    func status(runID: String) async throws -> BenchmarkRunStatus {
        guard let status = BenchmarkRegistry.shared.status(runID: runID) else { throw BenchmarkError.unknownRun(runID) }
        return status
    }

    func cancel(runID: String) async throws { BenchmarkRegistry.shared.cancel(runID: runID) }

    func latest() async -> BenchmarkRunStatus? { BenchmarkRegistry.shared.status(runID: nil) }
}

// MARK: - Model

/// State and actions behind Advanced → Benchmarks: pick suites and intensity,
/// run (after a confirmation that names the fleet pause), watch the poll, read
/// the results and the history of earlier runs. The measuring is
/// `BenchmarkRunner`'s; this only starts it, polls it and renders its report.
@MainActor
@Observable
final class BenchmarksModel {
    enum Phase: Equatable {
        case idle
        /// The confirmation was accepted and the run is being started.
        case starting
        case running(runID: String)
    }

    /// How the toolchains table is ordered.
    enum ToolchainSort: String, CaseIterable {
        case tool, install, verify, workload
    }

    // Choices
    var selectedSuites: Set<BenchmarkOptions.Suite> = Set(BenchmarkOptions.Suite.defaults)
    var intensity: BenchmarkOptions.Intensity = .quick
    var toolchainSort: ToolchainSort = .tool
    var toolchainSortAscending = true

    // State
    private(set) var phase: Phase = .idle
    private(set) var progress: BenchmarkProgress?
    private(set) var elapsed: TimeInterval = 0
    /// The report on screen: the finished run, or one picked from the history.
    private(set) var report: BenchmarkReport?
    /// Suites finished so far in the live run.
    private(set) var partials: [BenchmarkSuiteResult] = []
    private(set) var history: [BenchmarkReportStore.Entry] = []
    private(set) var status = StatusLine(text: "")

    // Collaborators
    @ObservationIgnored var runner: () -> any BenchmarkRunning = { LocalBenchmarkRunner() }
    @ObservationIgnored var store = BenchmarkReportStore()
    @ObservationIgnored var pollInterval: Duration = .seconds(2)
    /// Asks before a run starts. Real UI shows an alert; tests inject a closure.
    @ObservationIgnored var confirm: (_ title: String, _ message: String, _ button: String) -> Bool = {
        title, message, button in
        AlertKit.confirm(title: title, message: message, confirmTitle: button)
    }
    @ObservationIgnored var present: (Error) -> Void = {
        AlertKit.present(
            error: $0,
            title: String(localized: "Benchmark", bundle: .l10n, comment: "Alert title for a benchmark failure"))
    }
    /// Told when a run ends, with a one-line summary (the Fleet tab's card).
    @ObservationIgnored var onSummaryChanged: ((String?) -> Void)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    var isRunning: Bool { phase != .idle }

    // MARK: - Loading

    /// Reads the history from disk (cheap: a handful of small files) and, when nothing is on screen, shows the newest.
    func reload() {
        if !isRunning {
            Task { await attachToLiveRun() }
        }
        history = store.list()
        if report == nil, !isRunning, let newest = history.first, let loaded = try? store.load(newest.url) {
            // An unreadable file simply leaves the screen empty; the history list skipped it too.
            report = loaded
            onSummaryChanged?(summary(of: loaded))
        }
    }

    func show(_ entry: BenchmarkReportStore.Entry) {
        do {
            report = try store.load(entry.url)
        } catch {
            status = StatusLine(
                text: String(
                    localized: "Could not read that report — \(error.localizedDescription)", bundle: .l10n,
                    comment: "Benchmarks status line; %@ is the error's description"),
                style: .error)
        }
    }

    // MARK: - Options

    /// The options the current choices make. A thorough toolchains run covers the whole catalog (hours), which
    /// the confirmation says.
    func makeOptions() -> BenchmarkOptions {
        var options = BenchmarkOptions(
            suites: BenchmarkOptions.Suite.allCases.filter { selectedSuites.contains($0) }, intensity: intensity,
            includeHost: false)
        options.allToolchains = selectedSuites.contains(.toolchains)
        return options
    }

    var canRun: Bool { !selectedSuites.isEmpty && !isRunning }

    /// Says what a thorough toolchains run costs, or nil.
    var toolchainsWarning: String? {
        guard selectedSuites.contains(.toolchains), intensity == .thorough else { return nil }
        return String(
            localized:
                "A thorough toolchains run installs every tool in the catalog on a fresh guest and takes hours.",
            bundle: .l10n, comment: "Benchmarks warning under the suite toggles")
    }

    // MARK: - Run

    /// Run… → confirmation → start → poll.
    func runClicked() {
        guard canRun else { return }
        phase = .starting
        status = StatusLine(text: "")
        report = nil
        partials = []
        progress = nil
        Task { await start() }
    }

    private func start() async {
        let runner = self.runner()
        do {
            let impact = try await runner.impact()
            guard confirmRun(impact: impact) else {
                phase = .idle
                return
            }
            var options = makeOptions()
            options.confirmed = true
            let runID = try await runner.start(options)
            phase = .running(runID: runID)
            pollTask = Task { [weak self] in await self?.poll(runID: runID, runner: runner) }
        } catch {
            phase = .idle
            present(error)
            status = StatusLine(text: error.localizedDescription, style: .error)
        }
    }

    private func confirmRun(impact: BenchmarkFleetImpact) -> Bool {
        let title = String(localized: "Run the benchmark?", bundle: .l10n, comment: "Benchmarks confirmation title")
        let activeCount = impact.active
        var message =
            activeCount > 0
            ? String(
                localized:
                    "The fleet has \(activeCount) live VMs. It is paused while the benchmark runs and resumed afterwards; busy VMs finish their jobs first.",
                bundle: .l10n, comment: "Benchmarks confirmation body; plural by the number of live VMs")
            : String(
                localized: "The benchmark creates temporary VMs and containers and removes them when it ends.",
                bundle: .l10n, comment: "Benchmarks confirmation body")
        if let warning = toolchainsWarning { message += "\n\n" + warning }
        return confirm(
            title, message, String(localized: "Run", bundle: .l10n, comment: "Benchmarks confirmation button"))
    }

    /// Polls until the run ends. Cancelling this task (leaving the section) does not cancel the run: it lives in
    /// the daemon or the app's registry, and the next `attach` picks it up.
    private func poll(runID: String, runner: any BenchmarkRunning) async {
        while !Task.isCancelled {
            do {
                let run = try await runner.status(runID: runID)
                apply(run)
                if run.state.isFinal { return }
            } catch {
                finish(error: error)
                return
            }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return
            }
        }
    }

    private func apply(_ run: BenchmarkRunStatus) {
        progress = run.progress
        partials = run.progress.completed
        elapsed = run.elapsedSeconds
        switch run.state {
        case .running:
            break
        case .finished:
            report = run.report
            phase = .idle
            history = store.list()
            status = StatusLine(
                text: String(localized: "Benchmark finished.", bundle: .l10n, comment: "Benchmarks status line"),
                style: .ok)
            onSummaryChanged?(run.report.map(summary(of:)))
        case .failed:
            phase = .idle
            status = StatusLine(text: run.error ?? "", style: .error)
            present(BenchmarkError.stepFailed(step: "benchmark", detail: run.error ?? ""))
        case .cancelled:
            phase = .idle
            status = StatusLine(
                text: String(localized: "Benchmark cancelled.", bundle: .l10n, comment: "Benchmarks status line"))
        }
    }

    private func finish(error: Error) {
        phase = .idle
        status = StatusLine(text: error.localizedDescription, style: .error)
        present(error)
    }

    /// Stops the live run; it removes what it created before it ends.
    func cancelClicked() {
        guard case .running(let runID) = phase else { return }
        let runner = self.runner()
        Task {
            do {
                try await runner.cancel(runID: runID)
            } catch {
                present(error)
            }
        }
    }

    /// A run that is still going (started by the CLI, or before this window opened) shows its progress here.
    func attachToLiveRun() async {
        guard !isRunning, let latest = await runner().latest(), latest.state == .running else { return }
        attach(runID: latest.runID)
    }

    /// Re-attaches to a run another window or an earlier session started and is still going.
    func attach(runID: String) {
        guard !isRunning else { return }
        phase = .running(runID: runID)
        let runner = self.runner()
        pollTask = Task { [weak self] in await self?.poll(runID: runID, runner: runner) }
    }

    /// Stops polling (the section went away or the window closed); the run itself continues.
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Waits for the poll loop (tests).
    func waitForPoll() async { await pollTask?.value }
}
