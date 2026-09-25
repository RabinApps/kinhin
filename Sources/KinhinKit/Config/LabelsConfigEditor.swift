import Foundation
import Yams

/// Edits the fleet's label sets — the top-level `labels:` key (the fleet's
/// base pool) and `container.labels` (extra labels for the Apple-container
/// pool) — by targeted text surgery: comments and formatting elsewhere
/// survive, and the whole updated file must still parse through
/// `ConfigLoader.parse` before anything is written.
public enum LabelsConfigEditor {
    public enum Scope: String, CaseIterable, Sendable {
        /// Top-level `labels:` — every runner's base label set.
        case fleet
        /// `container.labels:` — extra labels on the Apple-container pool.
        case container
    }

    public static func labels(in yaml: String, scope: Scope) -> [String] {
        let partial = try? YAMLDecoder().decode(PartialConfig.self, from: yaml)
        switch scope {
        case .fleet:
            return partial?.labels ?? []
        case .container:
            return partial?.container?.labels ?? []
        }
    }

    /// Replace the scope's list and return the updated YAML text. The full
    /// file must still pass `ConfigLoader.parse` or nothing is written.
    @discardableResult
    public static func apply(_ newLabels: [String], scope: Scope, to url: URL = Paths.config) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RuntimesConfigError.notFound(url.path)
        }
        guard !newLabels.isEmpty else {
            throw RuntimesConfigError.validation(
                scope == .fleet
                    ? "labels must not be empty (the fleet's base label set)"
                    : "container.labels must not be empty when present (remove the key instead)"
            )
        }
        for label in newLabels where label.trimmingCharacters(in: .whitespaces).isEmpty {
            throw RuntimesConfigError.validation("labels must not contain blank entries")
        }

        let original = try String(contentsOf: url, encoding: .utf8)
        let updated: String
        switch scope {
        case .fleet:
            updated = try replaceTopLevelList(in: original, newLabels: newLabels)
        case .container:
            updated = try replaceContainerLabels(in: original, newLabels: newLabels)
        }
        do {
            _ = try ConfigLoader.parse(updated)
        } catch {
            throw RuntimesConfigError.validation(error.localizedDescription)
        }
        try updated.write(toFile: url.path, atomically: true, encoding: .utf8)
        return updated
    }

    // MARK: - Text surgery

    /// A column-0 mapping key line (`key:`), not a comment.
    private static func isTopKey(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first != "#", first != "-" else { return false }
        return (line.count - line.drop(while: { $0 == " " }).count) == 0 && trimmed.hasSuffix(":")
    }

    private static func indent(of line: String) -> Int {
        line.count - line.drop(while: { $0 == " " }).count
    }

    /// Replace the block-sequence under the column-0 `labels:` key (block
    /// or flow style), or append the block when the key is absent. A
    /// trailing comment on the key line is preserved.
    static func replaceTopLevelList(in yaml: String, newLabels: [String]) throws -> String {
        guard let root = try Yams.compose(yaml: yaml), root.mapping != nil else {
            throw RuntimesConfigError.yamlParse("top level must be a mapping")
        }
        var lines = yaml.components(separatedBy: "\n")
        let block = ["labels:"] + newLabels.map { "  - \"\($0.escaped())\"" }

        guard let start = lines.firstIndex(where: { isLabelsKey($0, at: 0) }) else {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast()
            }
            lines.append(contentsOf: block)
            return lines.joined(separator: "\n")
        }

        let trimmed = lines[start].trimmingCharacters(in: .whitespaces)
        if trimmed != "labels:" {
            // Flow style on the key line ("labels: [a, b]" or with a
            // trailing comment): replace just that line.
            var replacement = block
            if let commentRange = trimmed.range(of: " #") {
                replacement[replacement.count - 1] += " " + trimmed[commentRange.lowerBound...]
            }
            lines.replaceSubrange(start..<(start + 1), with: replacement)
            return lines.joined(separator: "\n")
        }

        var end = lines.count
        for index in (start + 1)..<lines.count where !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            if isTopKey(lines[index]) || indent(of: lines[index]) == 0 {
                end = index
                break
            }
        }
        lines.replaceSubrange(start..<end, with: block)
        return lines.joined(separator: "\n")
    }

    /// Replace the `labels:` list inside the `container:` block (indent 2,
    /// block or flow style). Inserts the key right after `container:` when
    /// the block lacks it.
    static func replaceContainerLabels(in yaml: String, newLabels: [String]) throws -> String {
        guard let root = try Yams.compose(yaml: yaml), root.mapping != nil else {
            throw RuntimesConfigError.yamlParse("top level must be a mapping")
        }
        var lines = yaml.components(separatedBy: "\n")

        guard
            let containerIdx = lines.firstIndex(where: {
                isTopKey($0) && $0.trimmingCharacters(in: .whitespaces) == "container:"
            })
        else {
            throw RuntimesConfigError.validation(
                "no container: section in config — add it before setting container.labels")
        }
        // A flow-style container line (container: {…}) can't take children.
        let containerLine = lines[containerIdx].trimmingCharacters(in: .whitespaces)
        guard containerLine == "container:" else {
            throw RuntimesConfigError.yamlParse(
                "container: must use block style (one key per line) to edit container.labels")
        }

        let block = ["  labels:"] + newLabels.map { "    - \"\($0.escaped())\"" }

        // An existing labels: key at indent 2 within the container block.
        var labelsIdx: Int?
        for index in (containerIdx + 1)..<lines.count {
            let line = lines[index]
            if isTopKey(line) { break }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if indent(of: line) < 2 { break }
            if isLabelsKey(line, at: 2) {
                labelsIdx = index
                break
            }
        }

        if let start = labelsIdx {
            let trimmed = lines[start].trimmingCharacters(in: .whitespaces)
            if trimmed != "labels:" {
                // Flow style on the key line.
                var replacement = block
                if let commentRange = trimmed.range(of: " #") {
                    replacement[replacement.count - 1] += " " + trimmed[commentRange.lowerBound...]
                }
                lines.replaceSubrange(start..<(start + 1), with: replacement)
                return lines.joined(separator: "\n")
            }
            var end = lines.count
            for index in (start + 1)..<lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                if isTopKey(line) || indent(of: line) <= 2 {
                    end = index
                    break
                }
            }
            lines.replaceSubrange(start..<end, with: block)
        } else {
            lines.insert(contentsOf: block, at: containerIdx + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// A `labels:` key line at the given indent — plain, flow-valued, or
    /// with a trailing comment ("labels: [a, b]  # note").
    private static func isLabelsKey(_ line: String, at expectedIndent: Int) -> Bool {
        guard indent(of: line) == expectedIndent else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("labels:") else { return false }
        let rest = trimmed.dropFirst("labels:".count)
        return rest.isEmpty || rest.hasPrefix(" ")
    }
}

private extension String {
    /// YAML double-quoted scalar escaping for label values.
    func escaped() -> String {
        self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
