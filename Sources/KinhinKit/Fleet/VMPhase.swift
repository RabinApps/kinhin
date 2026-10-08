import Foundation

/// Lifecycle phases of a single runner VM.
public enum VMPhase: String, Codable, Sendable, CaseIterable {
    case cloning  // tart clone running
    case booting  // tart run launched, waiting for IP
    case registering  // SSH: config.sh + run.sh in flight
    case ready  // registered on GitHub, waiting for a job
    case busy  // runner picked up a job (busy=true)
    case deleting  // teardown in progress
    case failed  // hit an error; awaiting cleanup

    public var isActive: Bool {
        switch self {
        case .cloning, .booting, .registering, .ready, .busy: return true
        case .deleting, .failed: return false
        }
    }

    var isTerminal: Bool { self == .deleting || self == .failed }
}
