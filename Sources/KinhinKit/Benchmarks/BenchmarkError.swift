import Foundation

/// Failures of a benchmark run. Every case is a runtime-class problem (the CLI
/// exits 4); a usage mistake in a flag is caught earlier by the command table.
public enum BenchmarkError: LocalizedError, CategorizedError {
    /// An option value that cannot be run (bad URL scheme, payload over its cap, unknown toolchain).
    case invalidOption(String)
    /// The fleet has live VMs and the caller has not confirmed pausing it.
    case fleetBusy(active: Int, busy: Int)
    /// Busy VMs did not finish within the drain window.
    case drainTimeout(busy: Int)
    /// A requested runtime's prerequisites are not healthy.
    case runtimeUnavailable(runtime: RuntimeID, why: String)
    /// The runtime's image is not on this Mac.
    case imageMissing(runtime: RuntimeID, image: String)
    case insufficientDisk(neededGB: Int, freeGB: Int)
    /// Nothing selected could run.
    case nothingToRun(String)
    case alreadyRunning(runID: String)
    case unknownRun(String)
    /// A required step of a suite failed.
    case stepFailed(step: String, detail: String)
    /// The backend cannot run benchmarks (a fake, a daemon that predates them).
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalidOption(let why):
            return "invalid benchmark option: \(why)"
        case .fleetBusy(let active, let busy):
            return
                "the fleet has \(active) live VM(s) (\(busy) busy); a benchmark pauses it while it runs. "
                + "Confirm with --yes (the CLI) or the app's dialog."
        case .drainTimeout(let busy):
            return "\(busy) busy VM(s) did not finish in time; re-run with --force to benchmark anyway"
        case .runtimeUnavailable(let runtime, let why):
            return "the \(runtime.rawValue) runtime is not ready: \(why)"
        case .imageMissing(let runtime, let image):
            return "image '\(image)' is not on this Mac for \(runtime.rawValue); run `kinhin image prepare` first"
        case .insufficientDisk(let needed, let free):
            return "a benchmark needs about \(needed) GB free disk, but only \(free) GB is free"
        case .nothingToRun(let why):
            return "nothing to benchmark: \(why)"
        case .alreadyRunning(let runID):
            return "a benchmark is already running (\(runID))"
        case .unknownRun(let runID):
            return "no benchmark run '\(runID)'"
        case .stepFailed(let step, let detail):
            return "benchmark step '\(step)' failed: \(detail)"
        case .unsupported(let why):
            return "benchmarks are not supported here: \(why)"
        }
    }

    public var category: ErrorCategory { .runtime }
}
