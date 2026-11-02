import Foundation

// ScalePlan — disk admission: how many planned instances the free disk can hold.
extension ScalePlan {
    // MARK: - Disk

    /// The slots the disk can hold. Each new instance costs its per-instance disk plus the reserve;
    /// the first that does not fit ends the new instances and is reported. Host slots and warm
    /// claims cost none (a claimed VM is already on disk), so they are always admitted.
    /// The disk is per slot, not per runtime, because a named Tart image can be larger than the base.
    static func admitByDisk(
        _ slots: [Slot], freeDiskGB: Int, reserveGB: Int, diskPerInstanceGB: (Slot) -> Int
    ) -> (admitted: [Slot], blocked: (runtime: RuntimeID, availableGB: Int, neededGB: Int)?) {
        var free = freeDiskGB
        var admitted: [Slot] = []
        var blocked: (runtime: RuntimeID, availableGB: Int, neededGB: Int)?
        for slot in slots {
            if slot.runtime != .host, slot.claim == nil {
                if blocked != nil { continue }
                let perVM = diskPerInstanceGB(slot)
                let needed = perVM + reserveGB
                if free < needed {
                    blocked = (slot.runtime, free, needed)
                    continue
                }
                free -= perVM
            }
            admitted.append(slot)
        }
        return (admitted, blocked)
    }
}

extension Forge {
    /// Whether `queuedJobs()` counts jobs already running on a runner. True
    /// for the GitHub scale-set forge (`totalAssignedJobs`); classic forges
    /// report queued-only work, so a busy VM is no longer part of it.
    /// Scale-set is the only `.jitConfig` forge.
    var queueIncludesRunning: Bool {
        if case .jitConfig = registration { return true }
        return false
    }
}
