import Foundation

/// Edits one top-level key of a YAML video config as text, so comments, ordering and the rest of the file stay as the user wrote
/// them (a YAML round trip would drop the comments).
public enum VideoConfigEditor {
    /// Sets the top-level `music:` block of `text` to `track` (and `volume` / `credit` when given). An existing `music:` entry,
    /// whatever its shape (block, `{...}`, a name, `false`), is replaced where it stands; otherwise the block goes just before
    /// `scenes:`, or at the end. Returns the new text and whether something was replaced.
    public static func setMusic(
        in text: String, track: String, volume: Double? = nil, credit: String? = nil
    ) -> (text: String, replaced: Bool) {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: newline)
        let endsWithNewline = lines.last == ""
        if endsWithNewline { lines.removeLast() }

        var block = ["music:", "  track: \(quoted(track))"]
        if let volume { block.append("  volume: \(formatted(volume))") }
        if let credit, !credit.isEmpty { block.append("  credit: \(quoted(credit))") }

        var replaced = false
        if let start = lines.firstIndex(where: { isTopLevelKey($0, "music") }) {
            var end = start + 1
            while end < lines.count, isInsideBlock(lines[end]) { end += 1 }
            // Blank lines that end the block belong to what follows it.
            while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            lines.replaceSubrange(start..<end, with: block)
            replaced = true
        } else if let scenes = lines.firstIndex(where: { isTopLevelKey($0, "scenes") }) {
            lines.insert(contentsOf: block, at: scenes)
        } else {
            lines.append(contentsOf: block)
        }
        let joined = lines.joined(separator: newline)
        return (endsWithNewline || !replaced ? joined + newline : joined, replaced)
    }

    /// A line that starts the top-level key `key:` (not indented, not a comment).
    static func isTopLevelKey(_ line: String, _ key: String) -> Bool {
        guard line.hasPrefix(key) else { return false }
        let rest = line.dropFirst(key.count).drop { $0 == " " || $0 == "\t" }
        return rest.first == ":"
    }

    /// Part of the block above: indented, or blank. A comment at column 0 ends it.
    static func isInsideBlock(_ line: String) -> Bool {
        line.isEmpty || line.first == " " || line.first == "\t"
    }

    /// A double-quoted YAML scalar (always valid, whatever the text holds).
    public static func quoted(_ value: String) -> String {
        var out = "\""
        for character in value {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(character)
            }
        }
        return out + "\""
    }

    public static func formatted(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }
}
