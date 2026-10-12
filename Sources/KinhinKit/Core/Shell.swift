import Foundation
import Synchronization

/// A completed subprocess run.
public struct ShellResult: Sendable {
    let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }

    /// The part of stderr worth showing in an error: the tail (a failing script
    /// ends with its real error), minus apt/debconf chatter that is printed as
    /// a warning on every run of a minimal image and says nothing about the failure.
    public var failureExcerpt: String {
        let noise = ["debconf:", "dpkg-preconfigure", "apt-utils", "Selecting previously", "Preparing to unpack"]
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in !line.isEmpty && !noise.contains { line.contains($0) } }
        guard !lines.isEmpty else { return stderr.isEmpty ? "no error output (exit \(exitCode))" : "exit \(exitCode)" }
        return String(lines.suffix(8).joined(separator: "\n").suffix(700))
    }

    /// Non-empty, whitespace-trimmed lines of stdout (ids, names, references).
    var outputLines: [String] {
        stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

enum ShellError: LocalizedError {
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let why): return "Failed to launch process: \(why)"
        }
    }
}

/// Runs subprocesses. Injectable so tests can script fake tool output.
/// Implementations must honour task cancellation: terminate the still-running
/// child and throw `CancellationError`, so a caller cancelled mid-command does
/// not sit out the command's own timeout.
public protocol ShellRunning: Sendable {
    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult

    /// Like `run`, with `input` written to the child's stdin (then closed).
    /// For scripts that carry secrets: unlike an argv element, stdin is not
    /// listed by `ps`. The default refuses, so a conformer that cannot feed
    /// stdin fails loudly instead of silently dropping the script.
    func run(_ argv: [String], input: Data, cwd: URL?, timeout: TimeInterval) async throws -> ShellResult
}

public extension ShellRunning {
    func run(_ argv: [String], input: Data, cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        throw ShellError.launchFailed("this shell runner cannot feed stdin")
    }

    func run(_ argv: [String]) async throws -> ShellResult {
        try await run(argv, cwd: nil, timeout: 120)
    }
}

/// Real shell runner using Foundation's Process.
///
/// Honours task cancellation: cancelling the surrounding task terminates a
/// still-running child (SIGTERM) and the call throws `CancellationError` once
/// the child is reaped — nothing is left running and the pipes are still
/// drained. A command that finished before cancellation landed returns its
/// normal result. The per-call timeout watchdog (exit 124) is unchanged.
public struct Shell: ShellRunning {
    /// Seconds a child gets to honour SIGTERM before it is killed outright.
    let killGracePeriod: TimeInterval

    public init() {
        self.init(killGracePeriod: 5)
    }

    init(killGracePeriod: TimeInterval) {
        self.killGracePeriod = killGracePeriod
    }

    public func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        try await execute(argv, input: nil, cwd: cwd, timeout: timeout)
    }

    public func run(_ argv: [String], input: Data, cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        try await execute(argv, input: input, cwd: cwd, timeout: timeout)
    }

    /// A child that exits without reading its stdin must not kill us with
    /// SIGPIPE when we write the input; ignored once, process-wide.
    private static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    private func execute(_ argv: [String], input: Data?, cwd: URL?, timeout: TimeInterval) async throws
        -> ShellResult
    {
        guard let first = argv.first else {
            throw ShellError.launchFailed("empty argv")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: first)
        process.arguments = Array(argv.dropFirst())
        if let cwd {
            process.currentDirectoryURL = cwd
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Detach stdin unless there is input to deliver: subprocesses must
        // never wait on us.
        let inPipe = input == nil ? nil : Pipe()
        process.standardInput = inPipe ?? FileHandle.nullDevice
        if input != nil { _ = Self.ignoreSIGPIPE }

        // Accumulate concurrently so large outputs cannot deadlock the pipes. An empty chunk is end-of-file: the
        // handler detaches itself and signals, and the result is read only after both pipes have signalled. Without
        // that, a handler still holding its last chunk could be scheduled after the snapshot, losing the output.
        let outData = DataAccumulator()
        let errData = DataAccumulator()
        let outEOF = OneShotSignal()
        let errEOF = OneShotSignal()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                outEOF.fire()
            } else {
                outData.append(chunk)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                errEOF.fire()
            } else {
                errData.append(chunk)
            }
        }

        // Awaiting exit through the termination handler (instead of a blocking
        // `waitUntilExit`) keeps a long-running child from pinning a thread of
        // the cooperative pool for its whole lifetime.
        let exit = OneShotSignal()
        process.terminationHandler = { _ in exit.fire() }
        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed("\(first): \(error.localizedDescription)")
        }
        if let input, let inPipe {
            // Off the caller's task: a script larger than the pipe buffer
            // blocks until the child reads, and must not stall the wait below.
            let writer = inPipe.fileHandleForWriting
            Task.detached {
                // EPIPE just means the child stopped reading (it exited early).
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }

        // Timeout watchdog: a detached task sleeps out the timeout, then
        // terminates a still-running process. A late firing after `run`
        // returned holds a dead Process; the flag read is guarded either way.
        let didTimeOut = Mutex(false)
        let watchdog = Task.detached {
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return  // cancelled: the process already exited
            }
            let shouldTerminate = didTimeOut.withLock { flag -> Bool in
                guard !flag else { return false }
                flag = true
                return true
            }
            if shouldTerminate {
                terminate(process)
            }
        }
        defer { watchdog.cancel() }

        // Cancellation: Foundation's Process ignores cooperative cancellation,
        // so without this a cancelled caller would wait out the child's own
        // timeout (up to the 600s registration script). Terminating the child
        // unblocks the wait immediately; we still reap it and drain the pipes
        // before throwing, so nothing leaks. The wait itself is never aborted —
        // only the child's death ends it.
        let wasCancelled = Mutex(false)
        await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            wasCancelled.withLock { $0 = true }
            terminate(process)
        }

        // Both pipes must reach end-of-file before their output is read. A grandchild that keeps a pipe open holds this
        // wait, as it always has with the blocking read it replaces.
        await outEOF.wait()
        await errEOF.wait()

        // A command that finished before cancellation landed keeps its normal
        // result; one cut short by it surfaces as CancellationError, which the
        // engine's lifecycle treats as "exit without touching the store".
        if wasCancelled.withLock({ $0 }) {
            throw CancellationError()
        }

        let code = process.terminationStatus
        let timedOut = didTimeOut.withLock { $0 }
        let actual = timedOut ? Int32(124) : code  // 124 = timeout convention
        return ShellResult(
            exitCode: actual,
            stdout: outData.text,
            stderr: errData.text
        )
    }

    /// SIGTERM a still-running child, then SIGKILL it if it ignores that: a
    /// child that traps SIGTERM would otherwise hang the caller forever.
    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        let grace = killGracePeriod
        Task.detached {
            try? await Task.sleep(for: .seconds(grace))
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// One-shot "the child exited" signal that can be awaited from a task.
/// A one-shot signal: `fire` once, and any `wait` (before or after) returns. Used for process exit and pipe EOF.
private final class OneShotSignal: Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<Void, Never>)
        case fired
    }
    private let state = Mutex(State.pending)

    func fire() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            defer { state = .fired }
            if case .waiting(let continuation) = state { return continuation }
            return nil
        }
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyFired = state.withLock { state -> Bool in
                if case .fired = state { return true }
                state = .waiting(continuation)
                return false
            }
            if alreadyFired { continuation.resume() }
        }
    }
}
