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
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// `raw` without terminal escapes, with carriage-return rewrites resolved
    /// (a progress bar keeps its last state) and only its tail kept.
    static func clean(_ raw: String, limit: Int = PipelineLogText.limit) -> (text: String, truncated: Bool) {
        var text = raw
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
        guard text.count > limit else { return (text, false) }
        var tail = String(text.suffix(limit))
        // Start at a line boundary so the first line is whole.
        if let newline = tail.firstIndex(of: "\n") { tail = String(tail[tail.index(after: newline)...]) }
        return (tail, true)
    }

    // MARK: - GitHub step slicing

    /// The leading `2026-10-02T10:00:01.1234567Z ` timestamp of a log line.
    static func timestamp(of line: Substring) -> Date? {
        guard line.count >= 20, line.first == "2" else { return nil }
        let head = line.prefix(19)
        guard let parsed = PipelineParsing.date(String(head) + "Z") else { return nil }
        var fraction = 0.0
        let rest = line.dropFirst(19)
        if rest.first == ".", let end = rest.firstIndex(of: "Z") {
            fraction = Double("0" + rest[rest.startIndex..<end]) ?? 0
        } else if rest.first != "Z" {
            return nil
        }
        return parsed.addingTimeInterval(fraction)
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
