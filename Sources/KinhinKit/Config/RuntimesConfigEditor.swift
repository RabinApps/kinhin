import Foundation
import Yams

/// Errors surfaced by the Runtimes pane's config editing.
/// Reads and writes the `runtimes:` section of the config YAML while
/// preserving everything else byte-for-byte. The menu bar Runtimes pane
/// edits through this — never by re-serializing the whole document (Yams
/// would drop the user's comments).
///
/// Safety: `apply` refuses to write unless the *entire* updated file parses
/// through `ConfigLoader.parse`, so a bad edit can never land on disk.
public enum RuntimesConfigEditor {
    // MARK: Reading

    /// The runtimes section as YAML text, or nil when the file has none.
    public static func section(from yaml: String) throws -> String? {
        guard let root = try Yams.compose(yaml: yaml), root.mapping != nil else { return nil }
        guard let child = root.mapping?[Node("runtimes")] else { return nil }
        return try Yams.serialize(node: child)
    }

    /// The runtimes section parsed into the typed model (nil when absent).
    public static func parsed(from yaml: String) throws -> kinhinConfig.RuntimeConfig? {
        let partial = try YAMLDecoder().decode(PartialConfig.self, from: yaml)
        guard let rt = partial.runtimes else { return nil }
        return kinhinConfig.RuntimeConfig(
            defaultRuntime: rt.default ?? RuntimeID.tart.rawValue,
            budget: rt.budget ?? [:],
            routes: (rt.routes ?? []).compactMap { route in
                guard let pattern = route.pattern, let runtime = route.runtime else { return nil }
                return kinhinConfig.RuntimeConfig.Route(pattern: pattern, runtime: runtime)
            }
        )
    }

    // MARK: Writing

    /// Serialize the section with stable ordering (the pane's canonical form).
    public static func sectionText(_ rc: kinhinConfig.RuntimeConfig) -> String {
        var lines: [String] = ["runtimes:"]
        lines.append("  default: \(rc.defaultRuntime)")
        if !rc.budget.isEmpty {
            lines.append("  budget:")
            for (name, weight) in rc.budget.sorted(by: { $0.key < $1.key }) {
                lines.append("    \(name): \(formatWeight(weight))")
            }
        }
        if !rc.routes.isEmpty {
            lines.append("  routes:")
            for route in rc.routes {
                lines.append("    - pattern: \(quote(route.pattern))")
                lines.append("      runtime: \(route.runtime)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Upsert the `runtimes:` section on disk and return the updated text.
    /// The whole updated file must still parse through `ConfigLoader.parse`
    /// (the same validation the engine uses) or nothing is written.
    @discardableResult
    public static func apply(_ rc: kinhinConfig.RuntimeConfig, to url: URL = Paths.config) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigEditError.notFound(url.path)
        }
        let original: String
        do {
            original = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigEditError.notFound(url.path)
        }
        let updated = try replaceSection(in: original, with: rc)
        do {
            _ = try ConfigLoader.parse(updated)
        } catch {
            throw ConfigEditError.validation(error.localizedDescription)
        }
        try updated.write(toFile: url.path, atomically: true, encoding: .utf8)
        return updated
    }

    /// Replace (or append) the top-level `runtimes:` mapping by editing the
    /// raw text: the section spans from its top-level key line to the next
    /// top-level key. Comments and formatting elsewhere are untouched.
    static func replaceSection(in yaml: String, with rc: kinhinConfig.RuntimeConfig) throws -> String {
        // Structural sanity before surgery: must be a YAML mapping.
        guard let root = try Yams.compose(yaml: yaml), root.mapping != nil else {
            throw ConfigEditError.yamlParse("top level must be a mapping")
        }
        var lines = yaml.components(separatedBy: "\n")
        let newSection = sectionText(rc)

        // A top-level key: starts at column 0, not a comment, looks like `key:` or `key: value`.
        func isTopLevel(_ line: String) -> Bool {
            guard let first = line.first else { return false }
            guard first != " ", first != "#", first != "-" else { return false }
            return line.contains(":")
        }

        if let start = lines.firstIndex(where: { isTopLevel($0) && $0.hasPrefix("runtimes:") }) {
            var end = lines.count
            for index in (start + 1)..<lines.count where isTopLevel(lines[index]) {
                end = index
                break
            }
            lines.replaceSubrange(start..<end, with: newSection.components(separatedBy: "\n"))
        } else {
            // Append after the last content (trailing blank line dropped so
            // we don't accumulate separators on repeated edits).
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast()
            }
            lines.append(newSection)
        }
        return lines.joined(separator: "\n")
    }

    static func quote(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func formatWeight(_ weight: Double) -> String {
        String(format: "%g", weight)
    }
}
