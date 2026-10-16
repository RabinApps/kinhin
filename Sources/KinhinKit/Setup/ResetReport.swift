import Foundation

/// What ``ResetEverything/execute(_:tart:shell:stopFleet:uninstallDaemon:ensureDirs:)``
/// did, and what it left behind. A reset is only complete when nothing was
/// left behind: both surfaces show the leftovers instead of a plain success,
/// and the CLI ends with the "needs attention" exit code.
public struct ResetReport: Equatable, Sendable {
    /// One line per completed step ("removed the daemon LaunchAgent").
    public var completed: [String] = []
    /// What is still on the Mac, one user-readable line each: the plan's
    /// ``ResetPlan/planningProblems`` (what could not even be inventoried), then each
    /// removal that failed.
    public var leftBehind: [String] = []

    public init(completed: [String] = [], leftBehind: [String] = []) {
        self.completed = completed
        self.leftBehind = leftBehind
    }

    /// True when every planned step ran and nothing was left behind.
    public var isComplete: Bool { leftBehind.isEmpty }
}
