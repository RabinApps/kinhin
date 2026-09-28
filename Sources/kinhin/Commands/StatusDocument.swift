import Foundation
import KinhinKit

/// Machine-readable `kinhin status --json` contract: whether a daemon is
/// reachable and, when it is, the fleet snapshot — plus the fields scripts
/// actually gate on flattened to the top level, so `paused` and `autoResume`
/// read without descending into `fleet` or parsing prose. Nil fields are
/// omitted, giving a three-state encoding: absent = no information (no
/// daemon, or a daemon predating `autoResume`), false = known off,
/// true = on.
struct StatusDocument: Codable, Equatable, Sendable {
    var daemonRunning: Bool
    var fleet: FleetStatus?
    var running: Bool?
    var paused: Bool?
    var autoResume: Bool?
    var pollInterval: Int?
    /// Seconds since a forge last answered a queue poll — the freshness of
    /// `fleet.queueDepth`. Absent when never polled or unknown.
    var queueAgeSeconds: Int?

    init(daemonRunning: Bool, fleet: FleetStatus?) {
        self.daemonRunning = daemonRunning
        self.fleet = fleet
        self.running = fleet?.running
        self.paused = fleet?.paused
        self.autoResume = fleet?.autoResume
        self.pollInterval = fleet?.pollInterval
        if let polledAt = fleet?.queuePolledAt {
            self.queueAgeSeconds = max(0, Int(Date().timeIntervalSince(polledAt)))
        }
    }
}
