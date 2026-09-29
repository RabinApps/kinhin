import Foundation
import Synchronization

/// Thread-safe byte accumulator used while draining process pipes.
final class DataAccumulator: Sendable {
    private let data = Mutex(Data())

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        data.withLock { $0.append(chunk) }
    }

    var text: String {
        String(decoding: data.withLock { $0 }, as: UTF8.self)
    }
}
