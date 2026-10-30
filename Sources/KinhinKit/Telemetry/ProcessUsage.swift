import Darwin
import Foundation
import Synchronization

/// CPU and memory of the kinhin process itself, for `kinhin.process.*`. CPU is the share of one
/// core used since the previous sample, so the first sample reports nil rather than a made-up zero.
final class ProcessUsage: Sendable {
    private let previous = Mutex<(cpu: Double, at: ContinuousClock.Instant)?>(nil)

    struct Sample: Sendable, Equatable {
        var cpuUtilization: Double?
        var residentBytes: Int?
    }

    func sample() -> Sample {
        var usage = rusage()
        var cpu: Double?
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            let seconds =
                Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec)
                + Double(usage.ru_stime.tv_usec) / 1e6
            let now = ContinuousClock.now
            cpu = previous.withLock { state in
                defer { state = (seconds, now) }
                guard let before = state else { return nil }
                let wall = (now - before.at) / .seconds(1)
                guard wall > 0, seconds >= before.cpu else { return nil }
                return (seconds - before.cpu) / wall
            }
        }
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return Sample(cpuUtilization: cpu, residentBytes: status == KERN_SUCCESS ? Int(info.resident_size) : nil)
    }
}
