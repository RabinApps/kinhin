import Foundation
import Yams

// MARK: - Section toggles (gitea / container / docker)

extension GeneralConfigEditor {
    /// Remove or (re)write a whole top-level section block. `newText` renders
    /// the section when present.
    static func replaceSectionToggle(_ name: String, present: Bool, in yaml: String, newText: () -> String?) throws
        -> String
    {
        guard let root = try? Yams.compose(yaml: yaml), root.mapping != nil else {
            throw ConfigEditError.yamlParse("top level must be a mapping")
        }
        var lines = yaml.components(separatedBy: "\n")

        func isTopKey(_ line: String) -> Bool {
            guard let first = line.first, first != "#", first != "-" else { return false }
            return line.hasPrefix(line.trimmingCharacters(in: .whitespaces)) && line.contains(":")
        }

        if let start = lines.firstIndex(where: { isTopKey($0) && $0.trimmingCharacters(in: .whitespaces) == "\(name):" }
        ) {
            var end = lines.count
            for index in (start + 1)..<lines.count where isTopKey(lines[index]) {
                end = index
                break
            }
            if present {
                let block = (newText() ?? "").components(separatedBy: "\n")
                lines.replaceSubrange(start..<end, with: block)
            } else {
                lines.replaceSubrange(start..<end, with: [])
            }
            return lines.joined(separator: "\n")
        }
        guard present, let block = newText() else { return lines.joined(separator: "\n") }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        lines.append(contentsOf: block.components(separatedBy: "\n"))
        return lines.joined(separator: "\n")
    }

    static func sectionText(_ g: Snapshot.Gitea) -> String {
        """
        gitea:
          instance: \(quote(g.instance))
          scope: \(quote(g.scope))
        """
    }

    static func sectionText(_ c: Snapshot.Container) -> String {
        var lines = ["container:", "  image: \(quote(c.image))"]
        if let base = c.baseImage, !base.isEmpty { lines.append("  base_image: \(quote(base))") }
        lines += ["  cpus: \(c.cpus)", "  memory_gb: \(c.memoryGB)"]
        if let labels = c.labels { lines.append("  labels: [\(labels.map(quote).joined(separator: ", "))]") }
        return lines.joined(separator: "\n")
    }

    static func sectionText(_ d: Snapshot.Docker) -> String {
        var lines = ["docker:", "  image: \(quote(d.image))"]
        if let base = d.baseImage, !base.isEmpty { lines.append("  base_image: \(quote(base))") }
        lines += ["  cpus: \(d.cpus)", "  memory_gb: \(d.memoryGB)", "  max_slots: \(d.maxSlots)"]
        if let platform = d.platform, !platform.isEmpty { lines.append("  platform: \(quote(platform))") }
        return lines.joined(separator: "\n")
    }

    private static func quote(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
