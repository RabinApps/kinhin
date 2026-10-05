import Foundation
import Yams

/// Reads and writes the top-level `images:` list of the config YAML while
/// preserving everything else byte-for-byte (same approach as
/// `RuntimesConfigEditor`: edit the raw text, never re-serialize the document).
///
/// Safety: `apply` refuses to write unless the *entire* updated file parses
/// through `ConfigLoader.parse`, so a bad name or base can never land on disk.
public enum ImagesConfigEditor {
    /// The `images:` entries parsed from config text (empty when absent).
    public static func parsed(from yaml: String) throws -> [KinhinConfig.ImageConfig] {
        let partial = try YAMLDecoder().decode(PartialConfig.self, from: yaml)
        return (partial.images ?? []).compactMap { entry in
            guard let name = entry.name else { return nil }
            return KinhinConfig.ImageConfig(name: name, baseImage: entry.baseImage, labels: entry.labels)
        }
    }

    /// The canonical text of the section; empty for no images.
    static func sectionText(_ images: [KinhinConfig.ImageConfig]) -> String {
        guard !images.isEmpty else { return "" }
        var lines = ["images:"]
        for image in images {
            lines.append("  - name: \(YAMLText.quoted(image.name))")
            if let base = image.baseImage { lines.append("    base_image: \(YAMLText.quoted(base))") }
            if let labels = image.labels, !labels.isEmpty {
                lines.append("    labels: [\(labels.map(YAMLText.quoted).joined(separator: ", "))]")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Replaces the `images:` section on disk (an empty list removes it) and
    /// returns the updated text.
    @discardableResult
    public static func apply(_ images: [KinhinConfig.ImageConfig], to url: URL = Paths.config) throws -> String {
        try ConfigFileEdit.apply(to: url) { try replaceSection(in: $0, with: images) }
    }

    static func replaceSection(in yaml: String, with images: [KinhinConfig.ImageConfig]) throws -> String {
        guard let root = try Yams.compose(yaml: yaml), root.mapping != nil else {
            throw ConfigEditError.yamlParse("top level must be a mapping")
        }
        var lines = yaml.components(separatedBy: "\n")
        let newLines = sectionText(images).components(separatedBy: "\n").filter { !$0.isEmpty }
        let isTopLevel = YAMLText.isTopLevelKey

        if let start = lines.firstIndex(where: { isTopLevel($0) && $0.hasPrefix("images:") }) {
            var end = lines.count
            for index in (start + 1)..<lines.count where isTopLevel(lines[index]) {
                end = index
                break
            }
            lines.replaceSubrange(start..<end, with: newLines)
        } else if !newLines.isEmpty {
            YAMLText.trimTrailingBlankLines(&lines)
            lines.append(contentsOf: newLines)
        }
        return lines.joined(separator: "\n")
    }
}
