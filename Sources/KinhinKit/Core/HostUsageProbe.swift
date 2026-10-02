import Darwin
import Foundation
import Synchronization

/// Cumulative CPU ticks across all cores.
struct CPUTicks: Sendable, Equatable {
    var busy: UInt64
    var total: UInt64
}

/// Samples live host CPU and RAM use. CPU is a delta between two samples, so
/// the first `sample()` reports a nil `cpuPercent`.
public final class HostUsageProbe: Sendable {
    private let readTicks: @Sendable () -> CPUTicks?
    private let readMemory: @Sendable () -> (usedBytes: UInt64, totalBytes: UInt64)?
    private let previous = Mutex<CPUTicks?>(nil)

    public convenience init() {
        self.init(readTicks: Self.systemTicks, readMemory: Self.systemMemory)
    }

    init(
        readTicks: @escaping @Sendable () -> CPUTicks?,
        readMemory: @escaping @Sendable () -> (usedBytes: UInt64, totalBytes: UInt64)?
    ) {
        self.readTicks = readTicks
        self.readMemory = readMemory
    }

    /// Nil when the host's memory cannot be read.
    public func sample() -> HostUsage? {
        guard let memory = readMemory() else { return nil }
        let gb = 1024.0 * 1024.0 * 1024.0
        return HostUsage(
            cpuPercent: cpuPercentSinceLastSample(),
            memoryUsedGB: Double(memory.usedBytes) / gb,
            memoryTotalGB: Double(memory.totalBytes) / gb)
    }

    private func cpuPercentSinceLastSample() -> Double? {
        guard let now = readTicks() else { return nil }
        let before = previous.withLock { state -> CPUTicks? in
            defer { state = now }
            return state
        }
        guard let before, now.total > before.total, now.busy >= before.busy else { return nil }
        return Double(now.busy - before.busy) / Double(now.total - before.total) * 100
    }

    // MARK: - Mach

    static func systemTicks() -> CPUTicks? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard
            host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
                == KERN_SUCCESS, let info
        else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        let states = Int(CPU_STATE_MAX)
        for core in 0..<Int(cpuCount) {
            let base = core * states
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return CPUTicks(busy: busy, total: total)
    }

    /// Used = active + wired + compressed pages, the figure Activity Monitor
    /// reports as "Memory Used" (file cache is reclaimable and excluded).
    static func systemMemory() -> (usedBytes: UInt64, totalBytes: UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        guard total > 0 else { return nil }
        return (pages * UInt64(pageSize), total)
    }
}
