import Foundation

/// Bounds an operation by a deadline, even one that ignores cancellation.
///
/// A task group would wait for every child at scope exit, so a model call that
/// never honors cancellation would hold the caller past the deadline. This
/// races two unstructured tasks and resumes on whichever finishes first; the
/// loser is cancelled and its late result dropped.
enum HealingDeadline {
    static func run<T: Sendable>(
        seconds: Double, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeoutError = EngineError.healingFailed(
            "the model did not answer within \(Int(seconds))s")
        let tasks = Locked<[Task<Void, Never>]>([])
        defer { tasks.withLock { $0.forEach { $0.cancel() } } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let pending = Locked<CheckedContinuation<T, Error>?>(continuation)
                let finish: @Sendable (Result<T, Error>) -> Void = { result in
                    pending.withLock { slot in
                        defer { slot = nil }
                        return slot
                    }?.resume(with: result)
                }
                let work = Task {
                    do { finish(.success(try await operation())) } catch { finish(.failure(error)) }
                }
                let timer = Task {
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                        finish(.failure(timeoutError))
                    } catch {
                        // Cancelled once the operation finished: nothing to report.
                    }
                }
                tasks.withLock { $0 = [work, timer] }
            }
        } onCancel: {
            tasks.withLock { $0.forEach { $0.cancel() } }
        }
    }
}
