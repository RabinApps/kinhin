import Foundation
import KinhinKit
import Synchronization

/// Runs `body` and returns true when it finished, or false once `timeout`
/// elapsed first. Unlike a task group, a body that ignores cancellation can't
/// hold the caller past the timeout: it is left to finish on its own.
func runWithTimeout(_ timeout: Duration, _ body: @escaping @Sendable () async -> Void) async -> Bool {
    let once = Locked(false)
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        @Sendable func finish(_ completed: Bool) {
            let first = once.withLock { done -> Bool in
                defer { done = true }
                return !done
            }
            if first { continuation.resume(returning: completed) }
        }
        Task {
            await body()
            finish(true)
        }
        Task {
            // Cancelled only if the process is going away; nothing to report.
            try? await Task.sleep(for: timeout)
            finish(false)
        }
    }
}
