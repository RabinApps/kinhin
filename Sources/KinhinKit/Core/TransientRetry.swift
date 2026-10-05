import Foundation

/// Runs `operation`, retrying with exponential backoff (1s, 2s, ...) while
/// `isTransient` classifies the failure as worth another attempt. The last
/// error is rethrown once retries are exhausted; cancellation is never retried.
func withTransientRetry<T>(
    retries: Int = 2,
    baseDelay: TimeInterval = 1,
    isTransient: (Error) -> Bool,
    _ operation: () async throws -> T
) async throws -> T {
    var attempt = 0
    while true {
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard attempt < retries, isTransient(error) else { throw error }
            attempt += 1
            try await Task.sleep(for: .seconds(baseDelay * pow(2, Double(attempt - 1))))
        }
    }
}
