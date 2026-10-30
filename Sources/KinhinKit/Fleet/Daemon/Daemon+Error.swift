import Foundation

extension Daemon {
    enum DaemonError: LocalizedError, Equatable {
        case missingToken
        case executablePathUnavailable
        case alreadyRunning
        case lockFailed(String)
        /// `launchctl bootout` failed while the agent is still loaded, so
        /// loading the new one would keep the old daemon running.
        case bootoutFailed(String)
        /// `launchctl kickstart` failed, so a daemon from an older build keeps running after an upgrade.
        case restartFailed(String)
        /// `launchctl bootstrap` returned success but the daemon exited or is not running.
        case agentStartFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingToken: return "no GitHub token stored — run `kinhin auth`"
            case .executablePathUnavailable:
                return "could not determine the kinhin executable path; reinstall using an absolute binary path"
            case .alreadyRunning: return "a daemon is already running"
            case .lockFailed(let why): return "could not take the daemon lock: \(why)"
            case .restartFailed(let why):
                return "could not restart the daemon for this build (launchctl kickstart failed: \(why))"
            case .agentStartFailed(let why):
                return "launchctl bootstrapped the daemon but it is not healthy: \(why)"
            case .bootoutFailed(let why):
                return "could not stop the running daemon (launchctl bootout failed: \(why)) — run"
                    + " `launchctl bootout gui/$(id -u)/\(Daemon.label)` and retry"
            }
        }
    }
}
