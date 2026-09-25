import Foundation

/// A tiny mutex primitive (Swift 5.9-compatible stand-in for the 5.10 Mutex).
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
