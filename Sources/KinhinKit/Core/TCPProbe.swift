import Foundation
import Network
import Synchronization

/// A non-blocking TCP connect probe: true when something accepts a connection
/// on `host:port` within `timeout`. Used to wait for a guest's sshd without
/// spawning a process per attempt.
enum TCPProbe {
    static func isOpen(host: String, port: UInt16, timeout: Duration = .seconds(1)) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let gate = Gate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                gate.install(continuation) { connection.cancel() }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: gate.finish(true)
                    // `.waiting` is a refused/unreachable connect that the
                    // framework would retry; the caller does its own retrying.
                    case .waiting(let error):
                        noteWaiting(host: host, error: error)
                        gate.finish(false)
                    case .failed, .cancelled: gate.finish(false)
                    default: break
                    }
                }
                connection.start(queue: .global(qos: .utility))
                Task {
                    try? await Task.sleep(for: timeout)  // a lost race with `finish` is harmless
                    gate.finish(false)
                }
            }
        } onCancel: {
            gate.finish(false)
        }
    }

    private static let reportedWaiting = Mutex(false)

    /// Says once per process why a connect is not completing, so a block that
    /// never clears (macOS Local Network privacy shows up here as a path
    /// error, not a refusal) is visible in the log. A refused connect is the
    /// normal "sshd is not up yet" and is not reported.
    private static func noteWaiting(host: String, error: NWError) {
        if case .posix(let code) = error, code == .ECONNREFUSED { return }
        let first = reportedWaiting.withLock { reported -> Bool in
            defer { reported = true }
            return !reported
        }
        if first {
            Log.info("tcp-probe", "connect to \(host):22 is not completing: \(error) (retrying)")
        }
    }

    /// Resumes the continuation exactly once and tears the connection down.
    private final class Gate: Sendable {
        private struct State {
            var continuation: CheckedContinuation<Bool, Never>?
            var cancel: (@Sendable () -> Void)?
            var result: Bool?
        }
        private let state = Mutex(State())

        func install(_ continuation: CheckedContinuation<Bool, Never>, cancel: @escaping @Sendable () -> Void) {
            let early = state.withLock { state -> Bool? in
                if let result = state.result { return result }
                state.continuation = continuation
                state.cancel = cancel
                return nil
            }
            if let early { continuation.resume(returning: early) }
        }

        func finish(_ value: Bool) {
            let (continuation, cancel) = state.withLock {
                state -> (CheckedContinuation<Bool, Never>?, (@Sendable () -> Void)?) in
                guard state.result == nil else { return (nil, nil) }
                state.result = value
                defer {
                    state.continuation = nil
                    state.cancel = nil
                }
                return (state.continuation, state.cancel)
            }
            cancel?()
            continuation?.resume(returning: value)
        }
    }
}
