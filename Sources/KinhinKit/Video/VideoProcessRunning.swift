import Foundation

/// Runs a command with its output going straight to the user's terminal (a video build takes minutes and prints
/// progress; `Shell` would hold it all until the end). Injectable so tests need no container.
public protocol VideoProcessRunning: Sendable {
    /// Runs `argv` with the parent's stdin, stdout and stderr, and returns its exit code. Cancelling the task stops the child.
    func runInteractive(_ argv: [String]) async throws -> Int32
}

/// The real thing: a `Process` that inherits stdio.
public struct InheritedProcessRunner: VideoProcessRunning {
    public init() {}

    private final class Box: @unchecked Sendable {
        let process = Process()
    }

    public func runInteractive(_ argv: [String]) async throws -> Int32 {
        guard let first = argv.first else { throw VideoError.launchFailed("empty command") }
        let box = Box()
        box.process.executableURL = URL(fileURLWithPath: first)
        box.process.arguments = Array(argv.dropFirst())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                box.process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try box.process.run()
                } catch {
                    box.process.terminationHandler = nil
                    continuation.resume(throwing: VideoError.launchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
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
    final class LineSplitter: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()

        func feed(_ data: Data) -> [String] {
            lock.withLock {
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
            lock.withLock {
                defer { pending.removeAll() }
                return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
            }
        }
    }

    private final class Box: @unchecked Sendable {
        let process = Process()
    }

    public func runInteractive(_ argv: [String]) async throws -> Int32 {
        guard let first = argv.first else { throw VideoError.launchFailed("empty command") }
        let box = Box()
        box.process.executableURL = URL(fileURLWithPath: first)
        box.process.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        box.process.standardOutput = pipe
        box.process.standardError = pipe
        let splitter = LineSplitter()
        let onLine = onLine
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            for line in splitter.feed(data) { onLine(line) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                box.process.terminationHandler = { process in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    // Whatever the child wrote last, before the handler was removed.
                    let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                    for line in splitter.feed(rest) { onLine(line) }
                    if let last = splitter.finish() { onLine(last) }
                    continuation.resume(returning: process.terminationStatus)
                }
                do {
                    try box.process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    box.process.terminationHandler = nil
                    continuation.resume(throwing: VideoError.launchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
    }
}
