import Foundation
import Synchronization

/// Turns Ctrl-C into cooperative cancellation for the CLI. The first SIGINT
/// cancels the running command's task, so the command unwinds through its own
/// cleanup paths — an image build stops and deletes its scratch VM and keeps
/// the previous image — and the CLI then exits 130 (`CLIExit.cancelled`). A
/// second SIGINT exits immediately without waiting, as the escape hatch when
/// cleanup itself seems stuck. `fire()` is split from the DispatchSource so
/// tests can drive the signal side without a real signal.
final class InterruptBridge: Sendable {
    private enum State { case armed, cancelled }
    private let state = Mutex(State.armed)
    private let cancel: @Sendable () -> Void
    /// Replaces the process exit for the second Ctrl-C (tests); nil means a
    /// real `exit(CLIExit.cancelled.rawValue)`.
    private let exitNow: (@Sendable () -> Void)?

    init(cancel: @escaping @Sendable () -> Void, exitNow: (@Sendable () -> Void)? = nil) {
        self.cancel = cancel
        self.exitNow = exitNow
    }

    /// The signal landed (or a test fired it).
    func fire() {
        let action = state.withLock { state -> State in
            defer { state = .cancelled }
            return state
        }
        if case .cancelled = action {
            if let exitNow { exitNow() } else { exit(CLIExit.cancelled.rawValue) }
            return
        }
        cancel()
    }

    /// Installs the bridge on SIGINT. Returns the source, which the caller
    /// must keep alive for the process's lifetime. `kinhin start` parks on its
    /// own SIGINT handler (dispatchMain + engine stop) and is excluded by the
    /// caller.
    @discardableResult
    static func install(cancel: @escaping @Sendable () -> Void) -> DispatchSourceSignal? {
        signal(SIGINT, SIG_IGN)
        let bridge = InterruptBridge(cancel: cancel)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { bridge.fire() }
        source.resume()
        return source
    }
}
