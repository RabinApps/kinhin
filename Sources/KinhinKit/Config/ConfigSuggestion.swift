import Foundation

/// "Did you mean …?" matching for config keys and enum-like values.
enum ConfigSuggestion {
    /// The candidate closest to `input`, or nil when nothing is close enough
    /// to be a plausible typo. Comparison ignores case, `-` and `_`, so
    /// `max-runners` and `maxRunners` both find `max_runners`.
    static func closest(to input: String, in candidates: [String]) -> String? {
        let target = normalized(input)
        guard !target.isEmpty else { return nil }
        var best: (candidate: String, distance: Int)?
        for candidate in candidates {
            let distance = editDistance(target, normalized(candidate))
            if best == nil || distance < best!.distance { best = (candidate, distance) }
        }
        guard let best else { return nil }
        // A typo is a couple of keystrokes: allow more slack for longer names, never more than a third of them.
        let allowed = min(3, max(1, target.count / 3))
        return best.distance <= allowed ? best.candidate : nil
    }

    /// " — did you mean 'x'?" or "" when there is no close match.
    static func hint(for input: String, in candidates: [String]) -> String {
        closest(to: input, in: candidates).map { " — did you mean '\($0)'?" } ?? ""
    }

    static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0 != "_" && $0 != "-" }
    }

    /// Levenshtein distance (insert, delete, substitute), plus adjacent
    /// transposition as one edit (Damerau, restricted), which is the most
    /// common typing slip.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var twoAgo = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    current[j] = min(current[j], twoAgo[j - 2] + 1)
                }
            }
            twoAgo = previous
            previous = current
        }
        return previous[b.count]
    }
}
