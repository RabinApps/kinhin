import Foundation

/// How long the reconcile loop waits before its next pass.
///
/// `poll_interval` is the cadence whenever there is anything to react to.
/// Two things stretch it:
///
/// - **Idle**: a running fleet with no queue and no instances for
///   `idleGrace` polls every `idleInterval` instead. The grace keeps
///   multi-stage workflows (`needs:`) snappy: the fleet is briefly empty
///   between their jobs, and those gaps must not slow the next stage. A
///   paused fleet never backs off — its surfaces promise to re-check the
///   queue every `poll_interval`.
/// - **API budget**: as a forge's rate limit runs low the interval doubles
///   (below 25 %) or quadruples (below 10 %); once it is exhausted the loop
///   waits for the reset rather than polling into certain failure.
struct PollCadence: Sendable {
    /// Why the cadence is slower than `poll_interval`.
    enum Slowdown: String, Sendable {
        case idle
        case apiBudget = "API budget low"
    }

    static let idleGrace: TimeInterval = 300
    static let idleInterval = 60
    /// Longest wait for a rate-limit reset (GitHub resets hourly).
    static let maxBudgetWait = 900

    private(set) var idleSince: Date?

    /// The next interval in seconds, and why it is slower than `base` (nil
    /// when it is not). `budget` is the most constrained attached forge's.
    mutating func next(base: Int, idle: Bool, paused: Bool, budget: ForgeRateLimit?, now: Date = Date())
        -> (seconds: Int, slowdown: Slowdown?)
    {
        var seconds = base
        var slowdown: Slowdown?
        if idle, !paused {
            let since = idleSince ?? now
            idleSince = since
            if now.timeIntervalSince(since) >= Self.idleGrace, Self.idleInterval > base {
                seconds = Self.idleInterval
                slowdown = .idle
            }
        } else {
            idleSince = nil
        }
        if let budget {
            let stretched: Int
            if budget.remaining == 0 {
                let untilReset = Int(budget.resetAt.timeIntervalSince(now).rounded(.up))
                stretched = min(max(untilReset, base), Self.maxBudgetWait)
            } else if budget.fractionRemaining < ForgeRateLimit.lowFraction {
                stretched = base * 4
            } else if budget.fractionRemaining < ForgeRateLimit.tightFraction {
                stretched = base * 2
            } else {
                stretched = base
            }
            if stretched > seconds {
                seconds = stretched
                slowdown = .apiBudget
            }
        }
        return (seconds, slowdown)
    }

    /// The tightest budget among `limits`: the one with the smallest share
    /// left (an exhausted budget always wins).
    static func tightest(_ limits: [ForgeRateLimit]) -> ForgeRateLimit? {
        limits.min { $0.fractionRemaining < $1.fractionRemaining }
    }
}
