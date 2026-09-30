import Foundation

/// The read → edit → validate → write cycle every config editor shares:
/// the edited text is written only when the whole file still passes
/// `ConfigLoader.parse` (the engine's own validation), so a bad edit never
/// lands on disk.
enum ConfigFileEdit {
    /// Applies `edit` to the file's text and writes the result if it
    /// validates. Returns the written text.
    @discardableResult
    static func apply(to url: URL, _ edit: (String) throws -> String) throws -> String {
        let updated = try edit(read(url))
        try validate(updated)
        try updated.write(toFile: url.path, atomically: true, encoding: .utf8)
        return updated
    }

    /// The file's text; `notFound` when there is no file.
    static func read(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ConfigEditError.notFound(url.path) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Throws `validation` (with the loader's message) when `yaml` isn't a
    /// config the engine would accept.
    static func validate(_ yaml: String) throws {
        do {
            _ = try ConfigLoader.parse(yaml)
        } catch {
            throw ConfigEditError.validation(error.localizedDescription)
        }
    }
}

/// Line-level YAML helpers for the editors' text surgery (they edit text,
/// not a re-serialized document, so the user's comments survive).
enum YAMLText {
    /// A mapping key at column 0 (`key:` or `key: value`) — not a comment,
    /// list item or indented line.
    static func isTopLevelKey(_ line: String) -> Bool {
        guard let first = line.first, first != " ", first != "\t", first != "#", first != "-" else { return false }
        return line.contains(":")
    }

    /// Leading spaces.
    static func indent(of line: String) -> Int {
        line.count - line.drop(while: { $0 == " " }).count
    }

    /// A double-quoted scalar with `\` and `"` escaped.
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Drops trailing blank lines, so appending a section doesn't pile up
    /// separators on repeated edits.
    static func trimTrailingBlankLines(_ lines: inout [String]) {
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
    }
}
