import Foundation

/// Spaces out the starts of new instances: each lifecycle that asks to begin
/// provisioning is admitted at least `interval` after the previous one, so a
/// burst of clones does not stampede the disk. Replaces a sleep inside the
/// reconcile pass: the pass hands the instances to their lifecycles and moves
/// on, and each lifecycle waits for its own slot here.
actor SpawnPacer {
    private let interval: Duration
    private var nextSlot: ContinuousClock.Instant?

    init(interval: Duration) {
        self.interval = interval
    }

    /// Returns when this caller's slot arrives (at once for the first caller
    /// after an idle period). Throws `CancellationError` if the caller is
    /// cancelled while waiting; its slot is then simply left unused.
    func admit() async throws {
        let now = ContinuousClock.now
        let slot = max(now, nextSlot ?? now)
        nextSlot = slot + interval
        if slot > now { try await Task.sleep(until: slot, clock: .continuous) }
    }
}
