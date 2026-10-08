import Foundation
import Synchronization

extension Daemon {
    /// Thread-safe box around the "current" engine. A config edit that the
    /// running engine cannot adopt live (anything beyond routing) requires
    /// a rebuild — the server's handler keeps answering through this box
    /// while the swap happens.
    /// FleetEngine is checked-`Sendable` now, so the current-engine box is
    /// just a stdlib `Mutex` — no unchecked escape hatch needed.
    final class EngineRef: Sendable {
        private let wrapped: Mutex<FleetEngine?>

        public init(_ initial: FleetEngine? = nil) {
            wrapped = Mutex(initial)
        }

        public var engine: FleetEngine? {
            wrapped.withLock { $0 }
        }

        func set(_ engine: FleetEngine?) {
            wrapped.withLock { $0 = engine }
        }

        /// The tail of the serial chain: each `serialized` call runs after
        /// the previous one finished.
        private let tail = Mutex<Task<Void, Never>?>(nil)

        /// Run `operation` after every previously submitted one has finished
        /// (FIFO), so engine swaps never interleave.
        func serialized<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
            let task = tail.withLock { tail -> Task<T, Never> in
                let previous = tail
                let next = Task {
                    await previous?.value
                    return await operation()
                }
                tail = Task { _ = await next.value }
                return next
            }
            return await task.value
        }
    }
}
