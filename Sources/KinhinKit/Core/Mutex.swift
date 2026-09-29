import Foundation

/// A tiny mutex primitive for the macOS 14 deployment target: the standard
/// library's `Synchronization.Mutex` (the API this stands in for) requires
/// macOS 15. Keep the shape identical to the stdlib type so a future floor
/// bump is a mechanical find-and-replace plus `import Synchronization`.
final class Mutex<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    public init(_ value: T) {
        self.value = value
    }

    @discardableResult
    func withLock<R>(_ body: (inout T) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
