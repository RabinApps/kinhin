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

    /// The scope's current labels. Blank text (no config yet) has none;
    /// text that does not decode throws instead of reading as empty.
    public static func labels(in yaml: String, scope: Scope) throws -> [String] {
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let partial: PartialConfig
        do {
            partial = try YAMLDecoder().decode(PartialConfig.self, from: yaml)
        } catch {
            throw ConfigEditError.decoding(error)
        }
        switch scope {
        case .fleet:
            return partial.labels ?? []
        case .container:
            return partial.container?.labels ?? []
        }
    }

    /// Replace the scope's list and return the updated YAML text. The full
    /// file must still pass `ConfigLoader.parse` or nothing is written.
    @discardableResult
    public static func apply(_ newLabels: [String], scope: Scope, to url: URL = Paths.config) throws -> String {
        _ = try ConfigFileEdit.read(url)
        guard !newLabels.isEmpty else {
            throw ConfigEditError.validation(
                scope == .fleet
                    ? "labels must not be empty (the fleet's base label set)"
                    : "container.labels must not be empty when present (remove the key instead)"
            )
        }
        for label in newLabels where label.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ConfigEditError.validation("labels must not contain blank entries")
        }

        return try ConfigFileEdit.apply(to: url) { original in
            switch scope {
            case .fleet: return try replaceTopLevelList(in: original, newLabels: newLabels)
            case .container: return try replaceContainerLabels(in: original, newLabels: newLabels)
            }
        }
    }

    // MARK: - Text surgery

    /// Replace the block-sequence under the column-0 `labels:` key (block
    /// or flow style), or append the block when the key is absent. A
    /// trailing comment on the key line is preserved.
    static func replaceTopLevelList(in yaml: String, newLabels: [String]) throws -> String {
        guard let root = try Yams.compose(yaml: yaml), root.mapping != nil else {
            throw ConfigEditError.yamlParse("top level must be a mapping")
        }
        var lines = yaml.components(separatedBy: "\n")
        let block = ["labels:"] + newLabels.map { "  - \(YAMLText.quoted($0))" }

        guard let start = lines.firstIndex(where: { isLabelsKey($0, at: 0) }) else {
            YAMLText.trimTrailingBlankLines(&lines)
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
            if YAMLText.isTopLevelKey(lines[index]) || YAMLText.indent(of: lines[index]) == 0 {
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
            throw ConfigEditError.yamlParse("top level must be a mapping")
        }
        var lines = yaml.components(separatedBy: "\n")

        guard
            let containerIdx = lines.firstIndex(where: {
                YAMLText.isTopLevelKey($0) && $0.trimmingCharacters(in: .whitespaces) == "container:"
            })
        else {
            throw ConfigEditError.validation(
                "no container: section in config — add it before setting container.labels")
        }
        // A flow-style container line (container: {…}) can't take children.
        let containerLine = lines[containerIdx].trimmingCharacters(in: .whitespaces)
        guard containerLine == "container:" else {
            throw ConfigEditError.yamlParse(
                "container: must use block style (one key per line) to edit container.labels")
        }

        let block = ["  labels:"] + newLabels.map { "    - \(YAMLText.quoted($0))" }

        // An existing labels: key at indent 2 within the container block.
        var labelsIdx: Int?
        for index in (containerIdx + 1)..<lines.count {
            let line = lines[index]
            if YAMLText.isTopLevelKey(line) { break }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if YAMLText.indent(of: line) < 2 { break }
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
                if YAMLText.isTopLevelKey(line) || YAMLText.indent(of: line) <= 2 {
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
        guard YAMLText.indent(of: line) == expectedIndent else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("labels:") else { return false }
        let rest = trimmed.dropFirst("labels:".count)
        return rest.isEmpty || rest.hasPrefix(" ")
    }
}
