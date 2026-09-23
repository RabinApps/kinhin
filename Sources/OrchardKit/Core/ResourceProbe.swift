import Foundation

/// Snapshot of the host machine's resources. Codable because the doctor's
/// machine-readable document embeds the snapshot verbatim.
public struct HostResources: Sendable, Equatable, Codable {
    public let logicalCores: Int
    public let memoryGB: Int
    public let freeDiskGB: Int
    public let arm64: Bool
}

/// Pure budget math, separated from probing so it is unit-testable.
public enum Capacity {
    public struct Plan: Equatable, Sendable {
        /// Upper bound on simultaneous VMs implied by CPU, RAM and disk.
        public let maxConcurrent: Int
        /// Human-readable explanation of the binding constraint.
        public let bindingConstraint: String
        /// Whether the configured single-VM shape fits at all.
        public let fits: Bool
    }

    /// Compute how many VMs of the given shape fit on this host while
    /// respecting reserved headroom and the user's max_runners.
    public static func plan(host: HostResources, vmCPU: Int, vmMemoryGB: Int, reservedCPU: Int, reservedMemoryGB: Int, diskPerVMGB: Int, userMax: Int) -> Plan {
        let usableCPU = max(0, host.logicalCores - reservedCPU)
        let usableMem = max(0, host.memoryGB - reservedMemoryGB)

        let cpuCap = vmCPU > 0 ? usableCPU / vmCPU : 0
        let memCap = vmMemoryGB > 0 ? usableMem / vmMemoryGB : 0
        let diskCap = diskPerVMGB > 0 ? (host.freeDiskGB / diskPerVMGB) : Int.max

        var cap = min(cpuCap, memCap, diskCap)
        var binding = "none"
        if cap == cpuCap, cap != Int.max { binding = "cpu (need \(vmCPU) cores per VM, \(usableCPU) usable)" }
        if cap == memCap, memCap < cap || binding == "none", cap == memCap { binding = "memory (need \(vmMemoryGB) GB per VM, \(usableMem) GB usable)" }
        if diskPerVMGB > 0, diskCap <= cap { binding = "free disk (\(diskPerVMGB) GB per VM, \(host.freeDiskGB) GB free)" }

        cap = max(0, cap)
        let final = min(cap, userMax)
        let fits = vmCPU <= usableCPU && vmMemoryGB <= usableMem

        return Plan(
            maxConcurrent: final,
            bindingConstraint: binding,
            fits: fits
        )
    }
}

/// Probes real host resources via sysctl.
public struct ResourceProbe: Sendable {
    public init() {}

    public func snapshot() -> HostResources {
        HostResources(
            logicalCores: Self.logicalCores(),
            memoryGB: Self.totalMemoryGB(),
            freeDiskGB: Self.freeDiskGB(),
            arm64: Self.isArm64()
        )
    }

    static func logicalCores() -> Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.logicalcpu", &count, &size, nil, 0)
        return max(1, Int(count))
    }

    static func totalMemoryGB() -> Int {
        var mem: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &mem, &size, nil, 0)
        return Int(mem / (1024 * 1024 * 1024))
    }

    static func freeDiskGB() -> Int {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else {
            return 0
        }
        return Int(bytes / (1024 * 1024 * 1024))
    }

    static func isArm64() -> Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}
