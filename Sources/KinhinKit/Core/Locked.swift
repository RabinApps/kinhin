import Synchronization

/// A value guarded by a lock, as a reference type.
///
/// Use it instead of a local `let x = Mutex(...)` when two tasks (or a task and the code after it) share the value. `Mutex` is
/// noncopyable, and the Swift 6.3 compiler rejects a noncopyable `let` that a `Task` or `addTask` closure captures while the
/// enclosing task still uses it (`SendingClosureRisksDataRace`, "closure captures reference to mutable let"). A class is an
/// ordinary `Sendable` reference, so every task can hold it. The call shape matches `Mutex.withLock`.
public final class Locked<Value: Sendable>: Sendable {
    private let state: Mutex<Value>

    public init(_ initial: Value) {
        state = Mutex(initial)
    }

    @discardableResult
    public func withLock<Result: Sendable>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try state.withLock { value in try body(&value) }
    }
}
