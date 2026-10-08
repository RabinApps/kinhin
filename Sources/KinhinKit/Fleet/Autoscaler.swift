import Foundation

/// Pure desired-count policy, unit-testable without any I/O.
enum Autoscaler {
    /// How many runner VMs should exist right now.
    ///
    /// - queueDepth: label-matching queued jobs on GitHub
    /// - minRunners/maxRunners: config bounds
    /// - capacityCap: hard ceiling implied by host resources
    /// - runnersPerVM: registered runner processes per VM (many-to-one);
    ///   each VM absorbs this many queued jobs, so fewer VMs cover the queue
    static func desiredCount(
        queueDepth: Int,
        minRunners: Int,
        maxRunners: Int,
        capacityCap: Int,
        runnersPerVM: Int = 1
    ) -> Int {
        let cap = min(maxRunners, capacityCap)
        let demandVMs = Int(ceil(Double(queueDepth) / Double(max(1, runnersPerVM))))
        return min(max(demandVMs, minRunners), cap)
    }

    /// Total concurrent job slots the fleet offers: every VM (bounded by both
    /// config and host capacity) serves `runnersPerVM` jobs at once.
    static func jobCapacity(maxRunners: Int, capacityCap: Int, runnersPerVM: Int) -> Int {
        min(maxRunners, capacityCap) * max(1, runnersPerVM)
    }

    /// Records that count toward "a runner exists" (active phases only).
    static func activeCount(_ records: [VMRecord]) -> Int {
        records.count { $0.phase.isActive }
    }
}
