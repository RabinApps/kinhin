import Foundation

/// The demand snapshot a scale-set listener publishes to the engine.
public struct GitHubScaleSetSnapshot: Sendable, Equatable {
    /// Latest statistics from the scale-set API.
    public let statistics: GitHubScaleSetStatistics
    /// Queued job demand derived from tracked events. When the tracked count is
    /// lower than `statistics.totalAssignedJobs`, placeholder jobs are synthesized
    /// so `queuedJobs()` always meets GitHub's reported demand.
    ///
    /// Policies that decide VM counts off `queuedJobs()` should use the snapshot's
    /// `statistics.totalAssignedJobs` as the demand ceiling; the resolved job list
    /// may be a superset of the real demand when placeholders are synthesized.
    public let trackedJobs: [GitHubScaleSetJobEvent]
    /// Per-repo attribution from tracked events.
    public let attributedRepos: Set<String>
}
