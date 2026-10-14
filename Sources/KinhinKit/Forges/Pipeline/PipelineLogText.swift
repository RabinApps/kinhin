import Foundation

/// Turns a forge's raw log bytes into display text, and slices a GitHub-style
/// timestamped job log into one step's output.
enum PipelineLogText {
    /// The most recent characters kept of a log.
    static let limit = 200_000

    private static let escapes: [NSRegularExpression] = [
        // CSI (colors, cursor), OSC and APC strings (Buildkite's `_bk;t=…` timestamps), single-char escapes.
        #"\x{1B}\[[0-9;?]*[ -/]*[@-~]"#,
        #"\x{1B}[\]_^P][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)"#,
        #"\x{1B}[@-Z\\-_]"#,
        // GitLab section markers: section_start:1700000000:name[options]
        #"section_(start|end):\d+:[^\r\n]*\r?"#,
        // Constant patterns pinned by tests; a bad one would only leave its escapes in the log text.
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// How much of the raw log's end is cleaned at all (UTF-8 bytes). The
    /// display keeps `limit` characters, so cleaning more would be wasted
    /// regex work on a multi-megabyte job log.
    static let rawTailBytes = 1_048_576

    /// `raw` without terminal escapes, with carriage-return rewrites resolved
    /// (a progress bar keeps its last state) and only its tail kept.
    static func clean(
        _ raw: String, limit: Int = PipelineLogText.limit, rawTailBytes: Int = PipelineLogText.rawTailBytes
    ) -> (text: String, truncated: Bool) {
        var text = raw
        var trimmedHead = false
        // Only the tail can be shown: drop the head (at a line boundary)
        // before the regex passes touch it.
        if raw.utf8.count > rawTailBytes, rawTailBytes > 0 {
            let tailStart = raw.utf8.index(raw.utf8.endIndex, offsetBy: -rawTailBytes)
            if let newline = raw.utf8[tailStart...].firstIndex(of: UInt8(ascii: "\n")) {
                text = String(raw[raw.index(after: newline)...])
            } else {
                text = String(raw[tailStart...])
            }
            trimmedHead = true
        }
        for expression in escapes {
            text = expression.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        if text.contains("\r") {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                line.split(separator: "\r", omittingEmptySubsequences: true).last.map(String.init) ?? ""
            }.joined(separator: "\n")
        }
        // Walk back `limit` characters from the end instead of counting the
        // whole text (O(limit), not O(n)).
        guard let cut = text.index(text.endIndex, offsetBy: -limit, limitedBy: text.startIndex), cut > text.startIndex
        else { return (text, trimmedHead) }
        var tail = String(text[cut...])
        // Start at a line boundary so the first line is whole.
        if let newline = tail.firstIndex(of: "\n") { tail = String(tail[tail.index(after: newline)...]) }
        return (tail, true)
    }

    // MARK: - GitHub step slicing

    /// The leading `2026-10-02T10:00:01.1234567Z ` timestamp of a log line,
    /// hand-parsed (this runs once per line of a multi-megabyte log).
    static func timestamp(of line: Substring) -> Date? {
        let bytes = line.utf8
        guard bytes.count >= 20, bytes.first == UInt8(ascii: "2") else { return nil }
        var digits: [Int] = []
        digits.reserveCapacity(14)
        var iterator = bytes.makeIterator()
        // yyyy-MM-ddTHH:mm:ss with its separators in place.
        let layout: [UInt8?] = [
            nil, nil, nil, nil, UInt8(ascii: "-"), nil, nil, UInt8(ascii: "-"), nil, nil, UInt8(ascii: "T"), nil, nil,
            UInt8(ascii: ":"), nil, nil, UInt8(ascii: ":"), nil, nil,
        ]
        for separator in layout {
            guard let byte = iterator.next() else { return nil }
            if let separator {
                guard byte == separator else { return nil }
            } else {
                guard byte >= 48, byte <= 57 else { return nil }
                digits.append(Int(byte) - 48)
            }
        }
        let year = digits[0] * 1000 + digits[1] * 100 + digits[2] * 10 + digits[3]
        let month = digits[4] * 10 + digits[5]
        let day = digits[6] * 10 + digits[7]
        let hour = digits[8] * 10 + digits[9]
        let minute = digits[10] * 10 + digits[11]
        let second = digits[12] * 10 + digits[13]
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
        var fraction = 0.0
        guard let next = iterator.next() else { return nil }
        if next == UInt8(ascii: ".") {
            var scale = 0.1
            var terminated = false
            while let byte = iterator.next() {
                if byte == UInt8(ascii: "Z") {
                    terminated = true
                    break
                }
                guard byte >= 48, byte <= 57 else { return nil }
                fraction += Double(byte - 48) * scale
                scale /= 10
            }
            guard terminated else { return nil }
        } else if next != UInt8(ascii: "Z") {
            return nil
        }
        // Days since 1970-01-01 (proleptic Gregorian, Howard Hinnant's algorithm).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    /// The lines of a job log that belong to step `index`: from that step's
    /// start up to the next step's start. Step times have one-second
    /// resolution, so a boundary second goes to the later step. Lines without
    /// a timestamp (continuations) follow the line above them.
    static func slice(jobLog: String, steps: [PipelineStep], index: Int) -> String {
        guard steps.indices.contains(index), let start = steps[index].startedAt else { return "" }
        let lower = floorSecond(start)
        let upper = steps.dropFirst(index + 1).lazy.compactMap(\.startedAt).first.map(floorSecond)
        var inside = false
        var lines: [Substring] = []
        for line in jobLog.split(separator: "\n", omittingEmptySubsequences: false) {
            if let stamp = timestamp(of: line) {
                inside = stamp >= lower && (upper.map { stamp < $0 } ?? true)
            }
            if inside { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    private static func floorSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}
