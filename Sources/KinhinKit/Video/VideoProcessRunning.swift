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
