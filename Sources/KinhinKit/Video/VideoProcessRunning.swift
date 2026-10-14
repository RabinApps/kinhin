import Foundation
import Synchronization

/// Runs a command with its output going straight to the user's terminal (a video build takes minutes and prints
/// progress; `Shell` would hold it all until the end). Injectable so tests need no container.
public protocol VideoProcessRunning: Sendable {
    /// Runs `argv` with the parent's stdin, stdout and stderr, and returns its exit code. Cancelling the task stops the child.
    func runInteractive(_ argv: [String]) async throws -> Int32
}

/// Launches `process` and waits for it to exit. A task cancelled before the launch never starts the child; one cancelled
/// while it runs stops it (SIGTERM, which `docker run` and `container run` pass on to the build) and throws
/// `CancellationError` once it has exited, so callers can tell "stopped" from "failed".
private func runToExit(_ process: Process) async throws -> Int32 {
    // Immutable, so sharing it is safe; `@unchecked` only because `Process` is not marked `Sendable`.
    final class Box: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }
    let box = Box(process)
    let exit = OneShotSignal()
    process.terminationHandler = { _ in exit.fire() }
    try Task.checkCancellation()
    do {
        try process.run()
    } catch {
        process.terminationHandler = nil
        throw VideoError.launchFailed(error.localizedDescription)
    }
    // Installed after the launch: a cancellation that already landed runs the handler at once, with a child to stop.
    let cancelled = Locked(false)
    await withTaskCancellationHandler {
        await exit.wait()
    } onCancel: {
        cancelled.withLock { $0 = true }
        if box.process.isRunning { box.process.terminate() }
    }
    if cancelled.withLock({ $0 }) { throw CancellationError() }
    return process.terminationStatus
}

/// The real thing: a `Process` that inherits stdio.
public struct InheritedProcessRunner: VideoProcessRunning {
    public init() {}

    public func runInteractive(_ argv: [String]) async throws -> Int32 {
        guard let first = argv.first else { throw VideoError.launchFailed("empty command") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: first)
        process.arguments = Array(argv.dropFirst())
        return try await runToExit(process)
    }
}

/// Runs a command and hands its output, line by line, to `onLine` (stdout and stderr together): for the app, which shows a build's
/// progress in a window rather than a terminal. Cancelling the task stops the child.
public struct CapturingProcessRunner: VideoProcessRunning {
    let onLine: @Sendable (String) -> Void

    public init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    /// Splits a byte stream into lines, holding a partial line until its end arrives.
    final class LineSplitter: Sendable {
        private let state = Mutex(Data())

        func feed(_ data: Data) -> [String] {
            state.withLock { pending in
                pending.append(data)
                var lines: [String] = []
                // Progress bars rewrite a line with carriage returns: each rewrite counts as a line.
                while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let line = pending[pending.startIndex..<index]
                    pending.removeSubrange(pending.startIndex...index)
                    if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
                }
                return lines
            }
        }

        func finish() -> String? {
            state.withLock { pending in
                defer { pending.removeAll() }
                return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
            }
        }
    }

    public func runInteractive(_ argv: [String]) async throws -> Int32 {
        guard let first = argv.first else { throw VideoError.launchFailed("empty command") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: first)
        process.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let splitter = LineSplitter()
        let onLine = onLine
        // An empty chunk is end-of-file: the handler detaches itself and signals. The last partial line is handed over only
        // after that, so no chunk still in a handler can arrive after it (the same rule as `Shell`).
        let eof = OneShotSignal()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                eof.fire()
            } else {
                for line in splitter.feed(data) { onLine(line) }
            }
        }
        let outcome: Result<Int32, Error>
        do {
            outcome = .success(try await runToExit(process))
        } catch {
            guard process.processIdentifier != 0 else {
                pipe.fileHandleForReading.readabilityHandler = nil  // never launched: no end-of-file will come
                throw error
            }
            outcome = .failure(error)
        }
        await eof.wait()
        if let last = splitter.finish() { onLine(last) }
        return try outcome.get()
    }
}
