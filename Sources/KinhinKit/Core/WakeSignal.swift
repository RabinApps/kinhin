import Foundation
import Synchronization

/// A sleep that can be cut short: `sleep(until:)` returns early when
/// `signal()` is called (from any thread), so a poll loop can run its next
/// pass the moment something asks for one instead of sitting out a long wait.
///
/// A signal sent while nobody is waiting is remembered for the next wait
/// (one slot, not a count). Deliberately not an `AsyncStream`: cancelling a
/// stream's iterator terminates the stream for good, which would turn every
/// later wait into a spin.
public final class WakeSignal: Sendable {
    private struct State {
        var pending = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    public init() {}

    public func signal() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let waiter = state.waiter else {
                state.pending = true
                return nil
            }
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }

    public func sleep(for duration: Duration) async throws {
        try await sleep(until: ContinuousClock.now + duration)
    }

    /// Waits until `deadline` or a signal. Throws `CancellationError` when the task is cancelled.
    public func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await Task.sleep(until: deadline, clock: .continuous) }
            group.addTask { await self.waitForSignal() }
            _ = try await group.next()
            group.cancelAll()
        }
        try Task.checkCancellation()
    }

    private func waitForSignal() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if state.pending {
                        state.pending = false
                        return true
                    }
                    if Task.isCancelled { return true }
                    state.waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
        }
    }
}
