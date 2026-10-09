import Foundation
import Synchronization

/// Where a benchmark run stands, as `bench_status` and the app's poll see it.
public struct BenchmarkRunStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case running, finished, failed, cancelled

        public var isFinal: Bool { self != .running }
    }

    public var runID: String
    public var state: State
    public var progress: BenchmarkProgress
    public var startedAt: Date
    public var elapsedSeconds: Double
    /// The finished report (state `finished`).
    public var report: BenchmarkReport?
    public var error: String?

    public init(
        runID: String, state: State, progress: BenchmarkProgress, startedAt: Date, elapsedSeconds: Double,
        report: BenchmarkReport? = nil, error: String? = nil
    ) {
        self.runID = runID
        self.state = state
        self.progress = progress
        self.startedAt = startedAt
        self.elapsedSeconds = elapsedSeconds
        self.report = report
        self.error = error
    }
}

/// The benchmark runs of this process. A run takes minutes, longer than an
/// RPC call may, so the daemon (or the in-process app) starts it detached and
/// clients poll `status`. One run at a time: two would measure each other.
public final class BenchmarkRegistry: Sendable {
    public static let shared = BenchmarkRegistry()

    private struct Run: Sendable {
        let id: String
        let started: Date
        let sink: BenchmarkProgressSink
        var task: Task<Void, Never>?
        var state: BenchmarkRunStatus.State = .running
        var finished: Date?
        var report: BenchmarkReport?
        var error: String?
    }

    private struct State: Sendable {
        var runs: [String: Run] = [:]
        var order: [String] = []
    }

    private let state = Mutex(State())
    /// Finished runs kept for late `status` calls.
    private let keep = 5

    public init() {}

    /// Starts a run in the background and returns its id at once.
    @discardableResult
    public func start(options: BenchmarkOptions, environment: BenchmarkEnvironment) throws -> String {
        try options.validate()
        let sink = BenchmarkProgressSink()
        let runner = BenchmarkRunner(environment: environment, progress: sink)
        let id = runner.runID
        try state.withLock { state in
            if let live = state.runs.values.first(where: { $0.state == .running }) {
                throw BenchmarkError.alreadyRunning(runID: live.id)
            }
            state.runs[id] = Run(id: id, started: Date(), sink: sink)
            state.order.append(id)
            while state.order.count > keep {
                state.runs[state.order.removeFirst()] = nil
            }
        }
        let task = Task { [weak self] in
            do {
                let report = try await runner.run(options)
                self?.finish(id, state: .finished, report: report, error: nil)
            } catch is CancellationError {
                self?.finish(id, state: .cancelled, report: nil, error: "cancelled")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                Log.error("bench", "run \(id) failed: \(message)")
                self?.finish(id, state: .failed, report: nil, error: message)
            }
        }
        state.withLock { $0.runs[id]?.task = task }
        return id
    }

    /// The status of `runID`, or of the most recent run when nil.
    public func status(runID: String?) -> BenchmarkRunStatus? {
        state.withLock { state in
            guard let id = runID ?? state.order.last, let run = state.runs[id] else { return nil }
            let end = run.finished ?? Date()
            return BenchmarkRunStatus(
                runID: run.id, state: run.state, progress: run.sink.snapshot(), startedAt: run.started,
                elapsedSeconds: end.timeIntervalSince(run.started), report: run.report, error: run.error)
        }
    }

    /// Cancels the live run; its cleanup still removes everything it created. False when nothing was running.
    @discardableResult
    public func cancel(runID: String? = nil) -> Bool {
        let task = state.withLock { state -> Task<Void, Never>? in
            guard let id = runID ?? state.order.last, let run = state.runs[id], run.state == .running else {
                return nil
            }
            return run.task
        }
        task?.cancel()
        return task != nil
    }

    /// Waits for a run to end (tests, the CLI's in-process path).
    public func wait(runID: String) async {
        let task = state.withLock { $0.runs[runID]?.task }
        await task?.value
    }

    private func finish(
        _ id: String, state newState: BenchmarkRunStatus.State, report: BenchmarkReport?, error: String?
    ) {
        state.withLock { state in
            state.runs[id]?.state = newState
            state.runs[id]?.report = report
            state.runs[id]?.error = error
            state.runs[id]?.finished = Date()
        }
    }
}

// MARK: - Engine wiring

extension FleetEngine {
    /// The environment a benchmark started through this engine runs in: its config, tart and ssh, and the
    /// engine itself as the fleet to pause.
    public func benchmarkEnvironment(root: URL = BenchmarkReportStore.defaultDirectory) -> BenchmarkEnvironment {
        BenchmarkEnvironment(
            config: activeConfig, tart: tart, ssh: ssh, shell: Shell(), root: root,
            fleet: EngineFleetControl(engine: self))
    }
}
