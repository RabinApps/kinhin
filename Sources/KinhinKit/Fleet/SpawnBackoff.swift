import Foundation

/// Per-runtime brake on starting instances that keep failing to register.
///
/// A runner start can fail for reasons the next attempt will repeat (a bad
/// image, a runner binary that exits at once, a rejected JIT config). Without
/// a brake the reconcile loop deletes the failed instance and starts the next
/// one immediately, forever. After `threshold` failures in a row a runtime
/// waits 30 s, then 1 min, 2 min … capped at 10 min; one successful
/// registration clears it. Pure value type: callers pass the clock.
struct SpawnBackoff: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        var failures = 0
        var until: Date?
        var lastReason = ""
    }

    static let threshold = 2
    static let baseDelay: TimeInterval = 30
    static let maxDelay: TimeInterval = 600

    private(set) var entries: [RuntimeID: Entry] = [:]

    /// How long to wait after the `failures`-th consecutive failure.
    static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures >= threshold else { return 0 }
        let doublings = min(failures - threshold, 10)
        return min(maxDelay, baseDelay * pow(2, Double(doublings)))
    }

    /// Records a failed start and returns the wait now in force (0 = none yet).
    @discardableResult
    mutating func recordFailure(_ runtime: RuntimeID, reason: String, now: Date) -> TimeInterval {
        var entry = entries[runtime] ?? Entry()
        entry.failures += 1
        entry.lastReason = reason
        let delay = Self.delay(afterFailures: entry.failures)
        entry.until = delay > 0 ? now.addingTimeInterval(delay) : nil
        entries[runtime] = entry
        return delay
    }

    /// A runner registered: the runtime is healthy again.
    mutating func recordSuccess(_ runtime: RuntimeID) {
        entries[runtime] = nil
    }

    /// When spawns for `runtime` may resume, or nil when it is not held back.
    func blockedUntil(_ runtime: RuntimeID, now: Date) -> Date? {
        guard let until = entries[runtime]?.until, until > now else { return nil }
        return until
    }

    /// Runtimes held back at `now`.
    func blocked(now: Date) -> Set<RuntimeID> {
        Set(entries.keys.filter { blockedUntil($0, now: now) != nil })
    }

    /// One line for the status bar, or nil when nothing is held back.
    func summary(now: Date) -> String? {
        let held = entries.filter { blockedUntil($0.key, now: now) != nil }.sorted { $0.key.rawValue < $1.key.rawValue }
        guard let first = held.first else { return nil }
        let wait = Int((first.value.until?.timeIntervalSince(now) ?? 0).rounded(.up))
        let reason = first.value.lastReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = reason.isEmpty ? "" : ": \(String(reason.prefix(200)))"
        return
            "runner starts failing on \(first.key.rawValue) (\(first.value.failures) in a row) — retrying in \(wait)s\(detail)"
    }
}
