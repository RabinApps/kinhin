import Foundation

/// Caps how often one fix is tried for one problem, so a fix that does not
/// help is never retried in a hot loop. Each (problem, fix) pair gets
/// `maxAttempts` tries spaced at least `cooldown` apart; once spent, the
/// problem escalates (to the advisor, else to the user). Forgetting a problem
/// (it went away) resets its pairs. Pure value type: callers pass the clock.
struct HealingBudget: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        var attempts = 0
        var last: Date?
    }

    var maxAttempts: Int
    var cooldown: TimeInterval
    private(set) var entries: [String: Entry] = [:]

    init(maxAttempts: Int, cooldown: TimeInterval) {
        self.maxAttempts = max(1, maxAttempts)
        self.cooldown = cooldown
    }

    static func key(_ signal: HealingSignal, _ fix: Remediation) -> String {
        "\(signal.key)|\(fix.kind.rawValue):\(fix.subject ?? "")"
    }

    /// Every try for this pair is used up.
    func exhausted(_ signal: HealingSignal, _ fix: Remediation) -> Bool {
        (entries[Self.key(signal, fix)]?.attempts ?? 0) >= maxAttempts
    }

    /// Whether a try may run now: not exhausted and out of its cooldown.
    func allows(_ signal: HealingSignal, _ fix: Remediation, now: Date) -> Bool {
        guard !exhausted(signal, fix) else { return false }
        guard let last = entries[Self.key(signal, fix)]?.last else { return true }
        return now.timeIntervalSince(last) >= cooldown
    }

    /// The pair's last try is at least `cooldown` old (or there was none),
    /// whether or not tries are left.
    func cooledDown(_ signal: HealingSignal, _ fix: Remediation, now: Date) -> Bool {
        guard let last = entries[Self.key(signal, fix)]?.last else { return true }
        return now.timeIntervalSince(last) >= cooldown
    }

    mutating func record(_ signal: HealingSignal, _ fix: Remediation, now: Date) {
        let key = Self.key(signal, fix)
        var entry = entries[key] ?? Entry()
        entry.attempts += 1
        entry.last = now
        entries[key] = entry
    }

    /// Spends every remaining try of this pair (the fix ran but did not help).
    mutating func exhaust(_ signal: HealingSignal, _ fix: Remediation) {
        let key = Self.key(signal, fix)
        var entry = entries[key] ?? Entry()
        entry.attempts = max(entry.attempts, maxAttempts)
        entries[key] = entry
    }

    /// Drops every pair whose problem is not in `live` (signal keys).
    mutating func forget(keepingOnly live: Set<String>) {
        entries = entries.filter { entry in
            let signalKey = entry.key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
            return live.contains(signalKey)
        }
    }
}
