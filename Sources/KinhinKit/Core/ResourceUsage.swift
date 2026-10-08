import Foundation

/// Live CPU and RAM use of one VM or container. Every field is optional:
/// a probe that cannot measure a value leaves it nil rather than reporting 0.
public struct ResourceUsage: Codable, Sendable, Equatable {
    /// Containers: percent of one core (Docker's convention), so 250 means 2.5
    /// cores busy. Tart VMs: percent of the VM's own cores (0–100).
    public var cpuPercent: Double?
    public var memoryUsedMB: Int?
    /// The configured memory ceiling, when the source reports one.
    public var memoryLimitMB: Int?

    public init(cpuPercent: Double? = nil, memoryUsedMB: Int? = nil, memoryLimitMB: Int? = nil) {
        self.cpuPercent = cpuPercent
        self.memoryUsedMB = memoryUsedMB
        self.memoryLimitMB = memoryLimitMB
    }
}

/// Live CPU and RAM use of the host machine.
public struct HostUsage: Codable, Sendable, Equatable {
    /// Percent of the whole machine (0–100). Nil on the first sample, which has no tick delta.
    public var cpuPercent: Double?
    public var memoryUsedGB: Double
    public var memoryTotalGB: Double

    public init(cpuPercent: Double? = nil, memoryUsedGB: Double, memoryTotalGB: Double) {
        self.cpuPercent = cpuPercent
        self.memoryUsedGB = memoryUsedGB
        self.memoryTotalGB = memoryTotalGB
    }
}
