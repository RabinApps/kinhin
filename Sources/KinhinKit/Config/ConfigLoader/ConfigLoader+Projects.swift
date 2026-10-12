import Foundation
import Yams

extension ConfigLoader {
    // MARK: - Projects section

    /// Validates the `projects:` section: unique `owner/name` or `owner/*`
    /// patterns, each toolchain scope run through the same rules as the
    /// global `toolchains:` section.
    static func parseProjects(_ partials: [PartialConfig.PartialProject]) throws -> [KinhinConfig.ProjectConfig] {
        var projects: [KinhinConfig.ProjectConfig] = []
        var seen: Set<String> = []
        for partial in partials {
            guard let pattern = partial.pattern, !pattern.isEmpty else {
                throw ConfigError.invalid("projects entries need a non-empty pattern")
            }
            let segments = pattern.split(separator: "/", omittingEmptySubsequences: false)
            guard segments.count == 2, segments.allSatisfy({ !$0.isEmpty }),
                !segments[0].contains("*"), segments[1] == "*" || !segments[1].contains("*"),
                !pattern.contains("@")
            else {
                throw ConfigError.invalid("projects pattern '\(pattern)' must be owner/name or owner/*")
            }
            guard seen.insert(pattern.lowercased()).inserted else {
                throw ConfigError.invalid("duplicate projects pattern '\(pattern)'")
            }
            let toolchains = try partial.toolchains.map(Self.parseToolchains)
            projects.append(
                KinhinConfig.ProjectConfig(
                    pattern: pattern, repoFile: partial.repoFile ?? false, toolchains: toolchains,
                    shareCache: partial.shareCache == true ? true : nil))
        }
        return projects
    }
}

/// A repo's `.kinhin.yml`: the toolchains its jobs need, read at the job's
/// own ref. The file is untrusted input that decides what gets installed on
/// the host, so it is far stricter than `config.yaml`: only a `toolchains:`
/// section, only catalog tools and stacks, a size cap, no cache policy, and
/// no brew or free-form entries.
public enum ProjectFileLoader {
    /// The preferred location: one `.kinhin/` folder per repo for everything kinhin reads from it.
    public static let preferredFileName = ".kinhin/config.yml"
    /// The original location, still read when the preferred file is absent.
    public static let fileName = ".kinhin.yml"
    /// Where a forge client looks, in order; the first file that exists wins.
    public static let searchPaths = [preferredFileName, fileName]
    /// How the file is named in messages (it may be either of the two).
    static let label = ".kinhin config file"
    public static let maxBytes = 16 * 1024

    private static let allowedTopLevelKeys: Set<String> = ["toolchains"]
    private static let allowedToolchainKeys: Set<String> = ["specs", "stacks"]

    /// Parses a `.kinhin.yml`. Returns nil toolchains when the file declares
    /// none. Throws `ConfigError.invalid` with a user-readable reason.
    public static func parse(_ data: Data) throws -> KinhinConfig.ToolchainsConfig? {
        guard data.count <= maxBytes else {
            throw ConfigError.invalid("\(label) is larger than \(maxBytes / 1024) KB")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigError.invalid("\(label) is not valid UTF-8")
        }
        let root: Node?
        do {
            root = try Yams.compose(yaml: text)
        } catch {
            throw ConfigError.invalid("\(label) is not valid YAML: \(error.localizedDescription)")
        }
        guard let root else { return nil }  // empty file
        guard let mapping = root.mapping else {
            throw ConfigError.invalid("\(label) must be a mapping with a toolchains: section")
        }
        for key in mapping.keys {
            guard let name = key.string, allowedTopLevelKeys.contains(name) else {
                throw ConfigError.invalid(
                    "\(label): unsupported key '\(key.string ?? "?")' (only toolchains: is allowed)")
            }
        }
        guard let toolchainsNode = mapping["toolchains"] else { return nil }
        guard let toolchainsMap = toolchainsNode.mapping else {
            throw ConfigError.invalid("\(label): toolchains must be a mapping with specs: and/or stacks:")
        }
        for key in toolchainsMap.keys {
            guard let name = key.string, allowedToolchainKeys.contains(name) else {
                throw ConfigError.invalid(
                    "\(label): toolchains.\(key.string ?? "?") is not allowed in a repo file (only specs and stacks)"
                )
            }
        }
        let partial: PartialConfig.PartialToolchains
        do {
            partial = try YAMLDecoder().decode(
                PartialConfig.PartialToolchains.self, from: Yams.serialize(node: toolchainsNode))
        } catch {
            throw ConfigError.invalid("\(label): toolchains is malformed: \(error.localizedDescription)")
        }
        let toolchains = try ConfigLoader.parseToolchains(partial)
        // Repo files may only name tools kinhin curates: free-form mise
        // backends (`ubi:`, `npm:`, `cargo:` …) would let a repo pull
        // arbitrary code into an image built on this Mac.
        for spec in toolchains.specs ?? [] {
            let root = ToolchainCatalog.rootTool(of: spec)
            guard ToolchainCatalog.tool(id: root) != nil else {
                throw ConfigError.invalid(
                    "\(label): '\(root)' is not in the kinhin toolchain catalog (run `kinhin toolchains` to list it)"
                )
            }
        }
        if (toolchains.specs ?? []).isEmpty && (toolchains.stacks ?? []).isEmpty { return nil }
        return toolchains
    }
}
