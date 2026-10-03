import Foundation

/// Runs `transform` over `items` with at most `limit` running at once and
/// returns the results in input order (never completion order).
///
/// On failure the remaining work is cancelled and the error of the earliest
/// failing item is thrown (a sibling's cancellation never masks the real
/// error). An empty or one-item input skips the group.
func boundedMap<Item: Sendable, Output: Sendable>(
    _ items: [Item], limit: Int, _ transform: @escaping @Sendable (Item) async throws -> Output
) async throws -> [Output] {
    if items.isEmpty { return [] }
    if items.count == 1 || limit <= 1 {
        var outputs: [Output] = []
        outputs.reserveCapacity(items.count)
        for item in items { outputs.append(try await transform(item)) }
        return outputs
    }
    return try await withThrowingTaskGroup(of: (Int, Result<Output, Error>).self) { group in
        var results = [Output?](repeating: nil, count: items.count)
        var nextIndex = 0
        func addNext() {
            guard nextIndex < items.count else { return }
            let index = nextIndex
            let item = items[index]
            nextIndex += 1
            group.addTask {
                do { return (index, .success(try await transform(item))) } catch { return (index, .failure(error)) }
            }
        }
        for _ in 0..<min(limit, items.count) { addNext() }
        var failure: (index: Int, error: Error)?
        while let (index, result) = try await group.next() {
            switch result {
            case .success(let output):
                results[index] = output
            case .failure(let error):
                let isCancel = error is CancellationError
                // A real error outranks a cancellation; among equals the earliest index wins.
                if let current = failure {
                    let currentIsCancel = current.error is CancellationError
                    if (currentIsCancel && !isCancel) || (currentIsCancel == isCancel && index < current.index) {
                        failure = (index, error)
                    }
                } else {
                    failure = (index, error)
                }
                group.cancelAll()
            }
            if failure == nil { addNext() }
        }
        if let failure { throw failure.error }
        try Task.checkCancellation()
        return results.compactMap { $0 }
    }
}
