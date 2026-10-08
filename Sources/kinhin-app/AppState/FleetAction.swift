import KinhinKit

/// A fleet start, stop, requeue, or skip queued job, from any entry point
/// (menu, Fleet tab, App Intent).
enum FleetAction: Sendable, Equatable {
    case start
    case stop
    case requeueQueuedJobs(for: ForgeID)
    case skipQueuedJobs(for: ForgeID)
}
