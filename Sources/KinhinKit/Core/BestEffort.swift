import Foundation

/// Runs work whose failure must not change control flow (cleanup, cache
/// warming, idempotent teardown). A failure is logged as a warning instead of
/// being silently discarded; cancellation is not logged. Use this instead of a
/// bare `try?` whenever a failure could otherwise go unnoticed.
func bestEffort(_ component: String, _ what: String, _ body: () throws -> Void) {
    do {
        try body()
    } catch is CancellationError {
        return
    } catch {
        Log.warn(component, "\(what) failed: \(error.localizedDescription)")
    }
}

/// Async variant of ``bestEffort(_:_:_:)``.
func bestEffortAsync(_ component: String, _ what: String, _ body: () async throws -> Void) async {
    do {
        try await body()
    } catch is CancellationError {
        return
    } catch {
        Log.warn(component, "\(what) failed: \(error.localizedDescription)")
    }
}

/// Runs `body` in a fresh task that does not inherit the caller's cancellation,
/// and waits for it. Cancellation-path teardown needs this: a shell call made
/// from a cancelled task is refused (`Shell` throws CancellationError before
/// the child even starts), which would skip the very cleanup that cancellation
/// requires. A newly created task carries no cancellation state, so its calls
/// run.
func withoutCancellation<T: Sendable>(
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await Task.detached(priority: .utility) { try await body() }.value
}
