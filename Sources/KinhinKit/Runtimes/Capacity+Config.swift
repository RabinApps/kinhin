import Foundation

// Capacity — the fleet cap as a config asks for it. The engine, `kinhin
// doctor`/`status` and the Runtimes pane all size the fleet through here.
extension Capacity {
    /// The runtime a single-pool fleet runs on: Apple containers, else
    /// Docker slots, else Tart VMs.
    static func primaryRuntime(of config: KinhinConfig) -> RuntimeID {
        config.container != nil ? .appleContainer : config.docker != nil ? .docker : .tart
    }

    /// The fleet cap for `config` on `host`: the primary runtime's instance
    /// shape and disk footprint (explicit `disk_gb`, else the runtime
    /// default), within the reserve and `max_runners`.
    public static func plan(for config: KinhinConfig, host: HostResources) -> Plan {
        let primary = primaryRuntime(of: config)
        let shape = RuntimeCapacity.shape(of: primary, in: config)
        return plan(
            host: host,
            vmCPU: shape.cpu,
            vmMemoryGB: shape.memoryGB,
            reservedCPU: config.reserve.cpu,
            reservedMemoryGB: config.reserve.memoryGB,
            diskPerVMGB: ResourceProbe.effectiveDiskPerVMGB(diskGB: config.diskGB, runtime: primary),
            userMax: config.maxRunners
        )
    }
}
