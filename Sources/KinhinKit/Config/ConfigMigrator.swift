import Foundation
import Yams

/// The result of translating a config written for an older schema.
public struct ConfigMigration: Sendable, Equatable {
    /// The migrated config text. Equal to the input when there was nothing to migrate.
    public let yaml: String
    /// One line per translation made ("repo: acme/widgets -> accounts: github").
    public let changes: [String]
    /// Things the migrator could not translate or that need a person's eye.
    public let warnings: [String]

    /// True when the input already used the current schema.
    public var isNoop: Bool { changes.isEmpty }
}

/// Translates the keys the loader now rejects (`repo:`, `gitea:`, `forgejo:`,
/// the global `toolchains:`) into the current schema (`accounts:`,
/// `projects:`, `toolchain_cache:`). Works on text so comments and layout
/// elsewhere in the file survive, and never touches the disk: callers decide
/// whether to print or save the result.
public enum ConfigMigrator {
    /// What the removed-key errors tell the user to run.
    public static let hint = "`kinhin config migrate` translates the old keys"

    /// Translates `yaml`. Throws `ConfigError` only when the text is not YAML.
    public static func migrate(_ yaml: String) throws -> ConfigMigration {
        var migration = Migration(original: yaml)
        try migration.run()
        return migration.result
    }

    /// Reads the file at `url` and migrates its text (the file is not modified).
    public static func migrate(fileAt url: URL) throws -> ConfigMigration {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ConfigError.notFound(url.path) }
        do {
            return try migrate(String(contentsOf: url, encoding: .utf8))
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError.unreadable(url.path, reason: error.localizedDescription)
        }
    }
}

// MARK: - Migration

private struct Migration {
    let original: String
    private var lines: [String]
    private var changes: [String] = []
    private var warnings: [String] = []

    /// Top-level keys of the legacy schema.
    private static let legacyKeys = ["repo", "gitea", "forgejo", "toolchains"]

    init(original: String) {
        self.original = original
        self.lines = original.components(separatedBy: "\n")
    }

    var result: ConfigMigration {
        guard !changes.isEmpty else {
            return ConfigMigration(yaml: original, changes: [], warnings: warnings)
        }
        var text = lines.joined(separator: "\n")
        var out = warnings
        if let problem = Self.validationProblem(text) {
            out.append("the migrated config does not validate yet: \(problem)")
        }
        if !text.hasSuffix("\n") { text += "\n" }
        return ConfigMigration(yaml: text, changes: changes, warnings: out)
    }

    private static func validationProblem(_ text: String) -> String? {
        do {
            _ = try ConfigLoader.parse(text)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Driver

    mutating func run() throws {
        let document: Any?
        do {
            document = try Yams.load(yaml: original)
        } catch {
            throw ConfigError.invalid("not valid YAML — \(error)")
        }
        guard let root = document as? [String: Any], Self.legacyKeys.contains(where: { root[$0] != nil }) else {
            return
        }

        // Legacy keys whose block is rewritten, in file order, with the new entries they produce.
        var accountEntries: [[String]] = []
        var owners: [String] = []
        var accountSources: [String] = []

        if let repo = root["repo"] {
            if let scope = repo as? String, !scope.isEmpty {
                accountEntries.append(
                    accountLines(name: "github", forge: "github", scope: scope, instance: nil, labels: nil))
                owners.append(Self.owner(of: scope))
                accountSources.append("repo")
                changes.append("repo: \(scope) -> accounts: {name: github, forge: github, scope: \(scope)}")
            } else if repo is NSNull || (repo as? String)?.isEmpty == true {
                accountSources.append("repo")
                changes.append("repo: (empty) removed; there was no GitHub forge to migrate")
            } else {
                warnings.append("repo: is not a string; left in place for you to convert")
            }
        }
        for forge in ["gitea", "forgejo"] {
            guard let raw = root[forge] else { continue }
            if raw is NSNull {
                accountSources.append(forge)
                changes.append("\(forge): (empty) removed; there was no \(forge) forge to migrate")
            } else if let section = raw as? [String: Any], let scope = section["scope"] as? String, !scope.isEmpty {
                let instance = section["instance"] as? String
                if instance?.isEmpty != false {
                    warnings.append("\(forge): has no instance; fill in `instance:` on the migrated account")
                }
                let labels = section["labels"] as? [String]
                accountEntries.append(
                    accountLines(name: forge, forge: forge, scope: scope, instance: instance, labels: labels))
                owners.append(Self.owner(of: scope))
                accountSources.append(forge)
                changes.append("\(forge): \(scope) -> accounts: {name: \(forge), forge: \(forge), scope: \(scope)}")
            } else {
                warnings.append("\(forge): has no scope; left in place for you to convert")
            }
        }

        var projectEntries: [[String]] = []
        var cacheLines: [String] = []
        var toolchainsMigrated = false
        if let raw = root["toolchains"] {
            if raw is NSNull {
                toolchainsMigrated = true
                changes.append("toolchains: (empty) removed")
            } else if let section = raw as? [String: Any] {
                toolchainsMigrated = true
                let distinctOwners = Self.unique(owners)
                let patterns = distinctOwners.isEmpty ? ["OWNER/*"] : distinctOwners.map { "\($0)/*" }
                if distinctOwners.isEmpty {
                    warnings.append(
                        "toolchains: applied to every repo; no forge scope was found to derive a project pattern, "
                            + "so the new projects: entry uses the placeholder OWNER/* — replace it")
                } else {
                    warnings.append(
                        "toolchains: applied to every repo; it now applies to \(patterns.joined(separator: ", ")) "
                            + "only. Add more projects: entries for other owners")
                }
                for pattern in patterns {
                    projectEntries.append(projectLines(pattern: pattern, section: section))
                    changes.append("toolchains: -> projects: {pattern: \(pattern)}")
                }
                if let cache = section["cache"] as? [String: Any], root["toolchain_cache"] == nil {
                    cacheLines = cacheBlock(cache)
                    changes.append("toolchains.cache -> toolchain_cache:")
                } else if section["cache"] != nil {
                    warnings.append("toolchains.cache dropped: toolchain_cache: already exists")
                }
            } else {
                warnings.append("toolchains: is not a mapping; left in place for you to convert")
            }
        }

        // Rewrite the text. Accounts first (they decide where the block lands).
        applyAccounts(entries: accountEntries, sources: accountSources, existing: root["accounts"] != nil)
        applyProjects(
            entries: projectEntries, cache: cacheLines, remove: toolchainsMigrated,
            existingProjects: root["projects"] != nil)
    }

    // MARK: Text surgery

    /// Line range of a top-level `key:` block (the key line through its indented/list body).
    private func block(of key: String) -> Range<Int>? {
        let pattern = "^" + NSRegularExpression.escapedPattern(for: key) + #"\s*:(\s|$)"#
        guard let start = lines.firstIndex(where: { $0.range(of: pattern, options: .regularExpression) != nil })
        else { return nil }
        var end = start + 1
        var lastBody = start
        while end < lines.count {
            let line = lines[end]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = line.first, !trimmed.isEmpty else {
                end += 1
                continue
            }
            if first == " " || first == "\t" || first == "-" {
                lastBody = end
                end += 1
            } else if first == "#" {
                // A column-0 comment belongs to the block only when more body follows it.
                end += 1
            } else {
                break
            }
        }
        return start..<(lastBody + 1)
    }

    private mutating func applyAccounts(entries: [[String]], sources: [String], existing: Bool) {
        guard !sources.isEmpty else { return }
        let ranges = sources.compactMap { block(of: $0) }
        let flat = entries.flatMap { $0 }
        if flat.isEmpty {
            remove(ranges)
            return
        }
        if existing {
            guard let accounts = block(of: "accounts"), appendableList(accounts) else {
                warnings.append(
                    "accounts: already exists in a form the migrator cannot extend (flow style?); "
                        + "left \(sources.joined(separator: ", ")) in place — add the entries by hand")
                changes.removeAll { change in sources.contains { change.hasPrefix("\($0):") } }
                return
            }
            let indent = listIndent(accounts)
            let reindented = flat.map { indent + $0 }
            // Insert after the existing block, then remove the legacy blocks (indices shift, so insert last-to-first).
            var edits = ranges.map { ($0, [String]?.none) }
            edits.append((accounts.upperBound..<accounts.upperBound, reindented))
            apply(edits)
        } else if let first = ranges.min(by: { $0.lowerBound < $1.lowerBound }) {
            var edits = ranges.map { ($0, [String]?.none) }
            edits.removeAll { $0.0 == first }
            edits.append(
                (first, ["# Migrated from the old repo:/gitea:/forgejo: keys.", "accounts:"] + flat.map { "  " + $0 }))
            apply(edits)
        }
    }

    private mutating func applyProjects(
        entries: [[String]], cache: [String], remove: Bool, existingProjects: Bool
    ) {
        guard remove, let tool = block(of: "toolchains") else { return }
        let flat = entries.flatMap { $0 }
        var replacement: [String] = []
        var edits: [(Range<Int>, [String]?)] = []
        if !flat.isEmpty {
            if existingProjects {
                if let projects = block(of: "projects"), appendableList(projects) {
                    let indent = listIndent(projects)
                    edits.append((projects.upperBound..<projects.upperBound, flat.map { indent + $0 }))
                } else {
                    warnings.append(
                        "projects: already exists in a form the migrator cannot extend; "
                            + "left toolchains: in place — add the project entries by hand")
                    changes.removeAll { $0.hasPrefix("toolchains") }
                    return
                }
            } else {
                replacement +=
                    ["# Migrated from the old global toolchains: key.", "projects:"] + flat.map { "  " + $0 }
            }
        }
        if !cache.isEmpty { replacement += cache }
        edits.append((tool, replacement.isEmpty ? nil : replacement))
        apply(edits)
    }

    private mutating func remove(_ ranges: [Range<Int>]) {
        apply(ranges.map { ($0, nil) })
    }

    /// Applies replacements (nil = delete) from the bottom up so earlier indices stay valid.
    private mutating func apply(_ edits: [(Range<Int>, [String]?)]) {
        let ordered = edits.sorted {
            // Bottom-up; at the same line, deletions before insertions so an insert is never deleted.
            ($0.0.lowerBound, $0.0.isEmpty ? 0 : 1) > ($1.0.lowerBound, $1.0.isEmpty ? 0 : 1)
        }
        for (range, replacement) in ordered {
            lines.replaceSubrange(range, with: replacement ?? [])
        }
    }

    /// A block-style list we can append items to: the key line has no inline value and body items start with `-`.
    private func appendableList(_ range: Range<Int>) -> Bool {
        let keyLine = lines[range.lowerBound]
        let afterColon = keyLine.drop(while: { $0 != ":" }).dropFirst()
        let inline =
            afterColon.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard inline.isEmpty else { return false }
        return lines[range].dropFirst().contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") }
    }

    /// Leading whitespace of the first list item in a block (so appended items line up).
    private func listIndent(_ range: Range<Int>) -> String {
        guard
            let item = lines[range].dropFirst().first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") })
        else { return "  " }
        return String(item.prefix(while: { $0 == " " || $0 == "\t" }))
    }

    // MARK: YAML fragments

    private func accountLines(name: String, forge: String, scope: String, instance: String?, labels: [String]?)
        -> [String]
    {
        var out = ["- name: \(Self.quoted(name))", "  forge: \(forge)", "  scope: \(Self.quoted(scope))"]
        if let instance, !instance.isEmpty { out.append("  instance: \(Self.quoted(instance))") }
        if let labels { out.append("  labels: \(Self.flow(labels))") }
        return out
    }

    private func projectLines(pattern: String, section: [String: Any]) -> [String] {
        var out = ["- pattern: \(Self.quoted(pattern))"]
        var toolLines: [String] = []
        for key in ["specs", "brew", "stacks"] {
            if let list = section[key] as? [String], !list.isEmpty {
                toolLines.append("    \(key): \(Self.flow(list))")
            }
        }
        if !toolLines.isEmpty { out += ["  toolchains:"] + toolLines }
        if section["share_cache"] as? Bool == true { out.append("  share_cache: true") }
        if toolLines.isEmpty && section["share_cache"] as? Bool != true { out.append("  repo_file: false") }
        return out
    }

    private func cacheBlock(_ cache: [String: Any]) -> [String] {
        var out: [String] = []
        if let value = cache["auto_prune"] as? Bool { out.append("  auto_prune: \(value)") }
        if let value = cache["max_age_days"] as? Int { out.append("  max_age_days: \(value)") }
        if let value = cache["max_gb"] as? Int { out.append("  max_gb: \(value)") }
        return out.isEmpty ? [] : ["toolchain_cache:"] + out
    }

    private static func quoted(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func flow(_ list: [String]) -> String {
        "[" + list.map(quoted).joined(separator: ", ") + "]"
    }

    /// `acme/widgets` -> `acme`; a bare org stays itself.
    private static func owner(of scope: String) -> String {
        scope.split(separator: "/").first.map(String.init) ?? scope
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
