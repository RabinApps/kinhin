import Foundation
import Synchronization

/// Where a run is, for the app's poll and the CLI's progress lines.
public struct BenchmarkProgress: Codable, Sendable, Equatable {
    public var phase: String
    public var suite: String?
    public var runtime: String?
    public var step: String?
    /// Suites finished so far (the partials of `bench_status`).
    public var completed: [BenchmarkSuiteResult]

    public init(
        phase: String = "starting", suite: String? = nil, runtime: String? = nil, step: String? = nil,
        completed: [BenchmarkSuiteResult] = []
    ) {
        self.phase = phase
        self.suite = suite
        self.runtime = runtime
        self.step = step
        self.completed = completed
    }

    /// One short line, `boot › docker › exec-ready`.
    public var line: String {
        ([phase == "running" ? nil : phase, suite, runtime, step].compactMap { $0 }).joined(separator: " › ")
    }
}

/// A run's live progress behind a lock: the runner writes, a poller reads.
public final class BenchmarkProgressSink: Sendable {
    private let state = Mutex(BenchmarkProgress())
    private let onLine: (@Sendable (String) -> Void)?

    /// - Parameter onLine: called with each new progress line (the CLI prints it to stderr).
    public init(onLine: (@Sendable (String) -> Void)? = nil) {
        self.onLine = onLine
    }

    public func snapshot() -> BenchmarkProgress { state.withLock { $0 } }

    func set(phase: String? = nil, suite: String?? = nil, runtime: String?? = nil, step: String?? = nil) {
        let line = state.withLock { progress -> String in
            if let phase { progress.phase = phase }
            if let suite { progress.suite = suite }
            if let runtime { progress.runtime = runtime }
            if let step { progress.step = step }
            return progress.line
        }
        if !line.isEmpty { onLine?(line) }
    }

    func complete(_ result: BenchmarkSuiteResult) {
        state.withLock { $0.completed.append(result) }
    }
}
