import Foundation

extension Daemon {
    enum DaemonError: LocalizedError, Equatable {
        case missingToken
        case alreadyRunning
        case lockFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingToken: return "no GitHub token stored — run `kinhin auth`"
            case .alreadyRunning: return "a daemon is already running"
            case .lockFailed(let why): return "could not take the daemon lock: \(why)"
            }
        }
    }
}
