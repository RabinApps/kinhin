import Foundation
import Yams

// MARK: - Section toggles (container / docker)

extension GeneralConfigEditor {
    /// Remove or (re)write a whole top-level section block. `newText` renders
    /// the section when present.
    static func replaceSectionToggle(_ name: String, present: Bool, in yaml: String, newText: () -> String?) throws
        -> String
    {
        let root: Node?
        do {
            root = try Yams.compose(yaml: yaml)
        } catch {
            throw ConfigEditError.yamlParse(error.localizedDescription)
        }
        guard let root, root.mapping != nil else {
            throw ConfigEditError.yamlParse("top level must be a mapping")
        }
        var lines = yaml.components(separatedBy: "\n")

        let isTopKey = YAMLText.isTopLevelKey

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
        YAMLText.trimTrailingBlankLines(&lines)
        lines.append(contentsOf: block.components(separatedBy: "\n"))
        return lines.joined(separator: "\n")
    }

    static func sectionText(_ c: Snapshot.Container) -> String {
        var lines = ["container:"]
        if !c.enabled { lines.append("  enabled: false") }
        if !c.image.isEmpty || c.pools.isEmpty { lines.append("  image: \(YAMLText.quoted(c.image))") }
        if let base = c.baseImage, !base.isEmpty { lines.append("  base_image: \(YAMLText.quoted(base))") }
        lines += ["  cpus: \(c.cpus)", "  memory_gb: \(c.memoryGB)"]
        if let labels = c.labels { lines.append("  labels: [\(labels.map(YAMLText.quoted).joined(separator: ", "))]") }
        if let fleetLabels = c.fleetLabels { lines.append("  fleet_labels: \(fleetLabels)") }
        if c.minIdle > 0 { lines.append("  min_idle: \(c.minIdle)") }
        if c.docker { lines.append("  docker: \(dockerValue(cache: c.dockerCache))") }
        if !c.flags.isEmpty { lines.append("  flags: [\(c.flags.map(YAMLText.quoted).joined(separator: ", "))]") }
        if let platform = c.platform, !platform.isEmpty { lines.append("  platform: \(YAMLText.quoted(platform))") }
        if !c.pools.isEmpty {
            lines.append("  pools:")
            lines += c.pools.flatMap { $0.lines(indent: "    ") }
        }
        return lines.joined(separator: "\n")
    }

    /// `docker:` with Docker on, as the file writes it: `true`, or `{ cache: false }` when the cache is off.
    static func dockerValue(cache: Bool) -> String {
        cache ? "true" : "{ cache: false }"
    }

    static func sectionText(_ d: Snapshot.Docker) -> String {
        var lines = ["docker:"]
        if !d.enabled { lines.append("  enabled: false") }
        lines.append("  image: \(YAMLText.quoted(d.image))")
        if let base = d.baseImage, !base.isEmpty { lines.append("  base_image: \(YAMLText.quoted(base))") }
        lines += ["  cpus: \(d.cpus)", "  memory_gb: \(d.memoryGB)", "  max_slots: \(d.maxSlots)"]
        if let platform = d.platform, !platform.isEmpty { lines.append("  platform: \(YAMLText.quoted(platform))") }
        if let fleetLabels = d.fleetLabels { lines.append("  fleet_labels: \(fleetLabels)") }
        if d.minIdle > 0 { lines.append("  min_idle: \(d.minIdle)") }
        return lines.joined(separator: "\n")
    }
}
