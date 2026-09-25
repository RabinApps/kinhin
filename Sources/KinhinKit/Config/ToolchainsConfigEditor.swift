import Foundation
import Yams

/// What the user has chosen to preinstall, as the UI edits it. Catalog tools
/// and stacks map to a version ("" = the catalog default); anything the
/// catalog doesn't know is carried through verbatim so editing never drops
/// a hand-written entry.
public struct ToolchainsSelection: Equatable, Sendable {
    /// Catalog tool id → version ("" = default, e.g. node → node@22).
    public var tools: [String: String] = [:]
    /// Catalog stack id → pinned version ("" = default).
    public var stacks: [String: String] = [:]
    /// `toolchains.specs` entries whose root the catalog doesn't know (passed to mise).
    public var extraSpecs: [String] = []
    /// `toolchains.brew` entries (raw Homebrew formulas/casks; macOS only).
    public var extraBrew: [String] = []
    public var shareCache = false
    /// Existing cache-expiry policy, preserved untouched.
    public var cache: KinhinConfig.ToolchainsConfig.CachePolicy?

    public init() {}

    public var isEmpty: Bool {
        tools.isEmpty && stacks.isEmpty && extraSpecs.isEmpty && extraBrew.isEmpty && !shareCache && cache == nil
    }

    /// The engine-facing config this selection produces.
    public var config: KinhinConfig.ToolchainsConfig {
        let specs = ToolchainsConfigEditor.specStrings(for: self)
        return KinhinConfig.ToolchainsConfig(
            specs: specs.isEmpty ? nil : specs,
            brew: extraBrew.isEmpty ? nil : extraBrew,
            stacks: ToolchainsConfigEditor.stackStrings(for: self).nilIfEmpty,
            shareCache: shareCache ? true : nil,
            cache: cache
        )
    }
}

private extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}

/// Reads and writes the `toolchains:` section by targeted text surgery
/// (comments elsewhere preserved), validating the whole file through the
/// engine's own parser before anything is written.
public enum ToolchainsConfigEditor {
    // MARK: Reading

    public static func selection(from yaml: String) throws -> ToolchainsSelection {
        let cfg = try ConfigLoader.parse(yaml)
        return selection(from: cfg.toolchains)
    }

    public static func selection(from config: KinhinConfig.ToolchainsConfig?) -> ToolchainsSelection {
        var out = ToolchainsSelection()
        guard let config else { return out }
        for spec in config.specs ?? [] {
            let root = ToolchainCatalog.rootTool(of: spec)
            if ToolchainCatalog.tool(id: root) != nil {
                out.tools[root] = ToolchainStack.splitSpec(spec).version ?? ""
            } else {
                out.extraSpecs.append(spec)
            }
        }
        for name in config.stacks ?? [] {
            let (id, version) = ToolchainStack.splitSpec(name)
            out.stacks[id] = version ?? ""
        }
        out.extraBrew = config.brew ?? []
        out.shareCache = config.shareCache ?? false
        out.cache = config.cache
        return out
    }

    // MARK: Writing

    /// Catalog-ordered `specs` strings for a selection.
    static func specStrings(for selection: ToolchainsSelection) -> [String] {
        let known = ToolchainCatalog.tools.compactMap { entry -> String? in
            guard let version = selection.tools[entry.id] else { return nil }
            return version.isEmpty ? entry.id : "\(entry.id)@\(version)"
        }
        return known + selection.extraSpecs
    }

    static func stackStrings(for selection: ToolchainsSelection) -> [String] {
        ToolchainCatalog.stacks.compactMap { stack in
            guard let version = selection.stacks[stack.id] else { return nil }
            return version.isEmpty ? stack.id : "\(stack.id)@\(version)"
        }
    }

    /// Problems that would make the engine reject this selection (a tool that
    /// needs a runtime nobody selected). Empty = fine. Nothing is ever
    /// installed implicitly, so the user has to pick the runtime too.
    public static func requirementProblems(_ selection: ToolchainsSelection) -> [String] {
        func satisfied(_ requirement: ToolchainRequirement) -> Bool {
            switch requirement {
            case .node: return selection.tools["node"] != nil
            case .dotnet: return selection.tools["dotnet"] != nil
            }
        }
        var problems: [String] = []
        for entry in ToolchainCatalog.tools where selection.tools[entry.id] != nil {
            for requirement in entry.requires where !satisfied(requirement) {
                problems.append("\(entry.id) needs \(requirement.rawValue) — select \(requirement.rawValue) too.")
            }
        }
        for stack in ToolchainCatalog.stacks where selection.stacks[stack.id] != nil {
            for requirement in stack.requires where !satisfied(requirement) {
                problems.append("\(stack.id) needs \(requirement.rawValue) — select \(requirement.rawValue) too.")
            }
        }
        return problems
    }

    /// The `toolchains:` block for a selection (nil when nothing is selected).
    static func sectionText(_ selection: ToolchainsSelection) -> String? {
        guard !selection.isEmpty else { return nil }
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                + "\""
        }
        func list(_ items: [String]) -> String { "[" + items.map(quoted).joined(separator: ", ") + "]" }
        var lines = ["toolchains:"]
        let specs = specStrings(for: selection)
        if !specs.isEmpty { lines.append("  specs: \(list(specs))") }
        if !selection.extraBrew.isEmpty { lines.append("  brew: \(list(selection.extraBrew))") }
        let stacks = stackStrings(for: selection)
        if !stacks.isEmpty { lines.append("  stacks: \(list(stacks))") }
        if selection.shareCache { lines.append("  share_cache: true") }
        if let cache = selection.cache {
            lines.append("  cache:")
            if let auto = cache.autoPrune { lines.append("    auto_prune: \(auto)") }
            if let days = cache.maxAgeDays { lines.append("    max_age_days: \(days)") }
            if let gb = cache.maxGB { lines.append("    max_gb: \(gb)") }
        }
        return lines.joined(separator: "\n")
    }

    /// Rewrites the file text with the selection (or removes the section).
    static func replace(_ selection: ToolchainsSelection, in yaml: String) throws -> String {
        try GeneralConfigEditor.replaceSectionToggle("toolchains", present: !selection.isEmpty, in: yaml) {
            sectionText(selection)
        }
    }

    @discardableResult
    public static func apply(_ selection: ToolchainsSelection, to url: URL = Paths.config) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ConfigEditError.notFound(url.path) }
        let original = try String(contentsOf: url, encoding: .utf8)
        let updated = try replace(selection, in: original)
        do {
            _ = try ConfigLoader.parse(updated)
        } catch {
            throw ConfigEditError.validation(error.localizedDescription)
        }
        try updated.write(toFile: url.path, atomically: true, encoding: .utf8)
        return updated
    }

    // MARK: What lands where

    /// For one target platform: which selected entries get installed and which
    /// are skipped because that platform can't run them.
    public struct Plan: Equatable, Sendable {
        public let installing: [String]
        public let skipped: [String]
    }

    public static func plan(_ selection: ToolchainsSelection, for platform: ToolchainPlatform) -> Plan {
        let resolved = ToolchainCatalog.selection(from: selection.config, platform: platform)
        let skipped = Set(resolved.skippedEntries)
        let chosen =
            ToolchainCatalog.tools.map(\.id).filter { selection.tools[$0] != nil }
            + ToolchainCatalog.stacks.map(\.id).filter { selection.stacks[$0] != nil }
        var installing = chosen.filter { !skipped.contains($0) }
        installing += selection.extraSpecs
        if platform == .macOS { installing += selection.extraBrew }
        let skippedOut = chosen.filter { skipped.contains($0) } + (platform == .linux ? selection.extraBrew : [])
        return Plan(installing: installing, skipped: skippedOut)
    }
}
