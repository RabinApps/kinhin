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
    // MARK: - Reading

    /// The runtimes section as YAML text, or nil when the file has none.
    public static func section(from yaml: String) throws -> String? {
        guard let root = try Yams.compose(yaml: yaml), root.mapping != nil else { return nil }
        guard let child = root.mapping?[Node("runtimes")] else { return nil }
        return try Yams.serialize(node: child)
    }

    /// The runtimes section parsed into the typed model (nil when absent).
    public static func parsed(from yaml: String) throws -> KinhinConfig.RuntimeConfig? {
        let partial = try YAMLDecoder().decode(PartialConfig.self, from: yaml)
        guard let rt = partial.runtimes else { return nil }
        func resolve(_ name: String) throws -> RuntimeID {
            guard let id = RuntimeID(rawValue: name) else {
                let known = RuntimeID.allCases.map(\.rawValue)
                throw ConfigError.invalid(
                    "runtimes: unknown runtime '\(name)'\(ConfigSuggestion.hint(for: name, in: known)) "
                        + "(known: \(known.joined(separator: ", ")))")
            }
            return id
        }
        return KinhinConfig.RuntimeConfig(
            defaultRuntime: try rt.default.map(resolve) ?? .tart,
            budget: rt.budget ?? [:],
            routes: try (rt.routes ?? []).compactMap { route in
                guard let pattern = route.pattern, let name = route.runtime else { return nil }
                return KinhinConfig.RuntimeConfig.Route(
                    pattern: pattern, runtime: try resolve(name), consent: route.consent)
            }
        )
    }

    // MARK: - Writing

    /// Serialize the section with stable ordering (the pane's canonical form).
    static func sectionText(_ rc: KinhinConfig.RuntimeConfig) -> String {
        var lines: [String] = ["runtimes:"]
        lines.append("  default: \(rc.defaultRuntime.rawValue)")
        if !rc.budget.isEmpty {
            lines.append("  budget:")
            for (name, weight) in rc.budget.sorted(by: { $0.key < $1.key }) {
                lines.append("    \(name): \(formatWeight(weight))")
            }
        }
        if !rc.routes.isEmpty {
            lines.append("  routes:")
            for route in rc.routes {
                lines.append("    - pattern: \(YAMLText.quoted(route.pattern))")
                lines.append("      runtime: \(route.runtime.rawValue)")
                if let consent = route.consent {
                    lines.append("      consent: \(consent)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Upsert the `runtimes:` section on disk and return the updated text.
    /// The whole updated file must still parse through `ConfigLoader.parse`
    /// (the same validation the engine uses) or nothing is written.
    @discardableResult
    public static func apply(_ rc: KinhinConfig.RuntimeConfig, to url: URL = Paths.config) throws -> String {
        try ConfigFileEdit.apply(to: url) { try replaceSection(in: $0, with: rc) }
    }

    /// Replace (or append) the top-level `runtimes:` mapping by editing the
    /// raw text: the section spans from its top-level key line to the next
    /// top-level key. Comments and formatting elsewhere are untouched.
    static func replaceSection(in yaml: String, with rc: KinhinConfig.RuntimeConfig) throws -> String {
        // Structural sanity before surgery: must be a YAML mapping.
        guard let root = try Yams.compose(yaml: yaml), root.mapping != nil else {
            throw ConfigEditError.yamlParse("top level must be a mapping")
        }
        var lines = yaml.components(separatedBy: "\n")
        let newSection = sectionText(rc)

        let isTopLevel = YAMLText.isTopLevelKey

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
            YAMLText.trimTrailingBlankLines(&lines)
            lines.append(newSection)
        }
        return lines.joined(separator: "\n")
    }

    static func formatWeight(_ weight: Double) -> String {
        String(format: "%g", weight)
    }
}
