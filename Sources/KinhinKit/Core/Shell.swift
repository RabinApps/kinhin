import Foundation

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

    public var errorDescription: String? {
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
}

public extension ShellRunning {
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
    public init() {}

    public func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
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
        // Detach stdin: subprocesses must never wait on us.
        process.standardInput = FileHandle.nullDevice

        // Accumulate concurrently so large outputs cannot deadlock the pipes.
        let outData = DataAccumulator()
        let errData = DataAccumulator()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            outData.append(handle.availableData)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            errData.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed("\(first): \(error.localizedDescription)")
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
            if shouldTerminate, process.isRunning {
                process.terminate()
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
            process.waitUntilExit()
        } onCancel: {
            wasCancelled.withLock { $0 = true }
            guard process.isRunning else { return }
            process.terminate()
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        // Drain any final buffered bytes.
        outData.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        errData.append(errPipe.fileHandleForReading.readDataToEndOfFile())

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
}
