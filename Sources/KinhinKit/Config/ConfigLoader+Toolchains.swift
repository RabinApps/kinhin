import Foundation

extension ConfigLoader {
    // MARK: - Toolchains section

    /// Validates and resolves the `toolchain_cache:` section: non-negative
    /// limits, and `auto_prune: false` only alongside explicit limits.
    static func parseToolchainCache(_ cache: PartialConfig.PartialCachePolicy) throws -> KinhinConfig.ToolchainCacheConfig
    {
        if let auto = cache.autoPrune, auto == false, cache.maxAgeDays == nil, cache.maxGB == nil {
            throw ConfigError.invalid(
                "toolchain_cache: set auto_prune: false together with explicit max_age_days / max_gb values, or remove the section (the defaults are auto_prune: true, 30 days, 50 GB)"
            )
        }
        if let days = cache.maxAgeDays, days < 0 {
            throw ConfigError.invalid("toolchain_cache.max_age_days must be >= 0 (0 = no age limit)")
        }
        if let gb = cache.maxGB, gb < 0 {
            throw ConfigError.invalid("toolchain_cache.max_gb must be >= 0 (0 = no size limit)")
        }
        return KinhinConfig.ToolchainCacheConfig(
            autoPrune: cache.autoPrune, maxAgeDays: cache.maxAgeDays, maxGB: cache.maxGB)
    }

    /// Validates and resolves a toolchain set (`projects[].toolchains`).
    /// Beyond the usual
    /// shape checks (non-empty entries, no duplicates per list, non-negative
    /// cache values) this enforces the no-implicit-installs rule: a stack
    /// that needs a runtime (e.g. vercel → node) fails validation naming the
    /// fix, instead of silently installing the dependency.
    ///
    /// Public so the CLI can validate `image prepare --toolchain/--stack`
    /// flag overrides through the exact same rules as config parsing.
    public static func parseToolchains(_ partial: PartialConfig.PartialToolchains) throws
        -> KinhinConfig.ToolchainsConfig
    {
        let specs = try Self.parseList(partial.specs, key: "toolchains.specs")
        let brew = try Self.parseList(partial.brew, key: "toolchains.brew")
        let stackNames = try Self.parseList(partial.stacks, key: "toolchains.stacks")
        // These reach bake scripts: shell metacharacters, spaces and a leading
        // `-` are rejected up front.
        try Self.requireSafeEntries(specs, key: "toolchains.specs")
        try Self.requireSafeEntries(brew, key: "toolchains.brew")
        try Self.requireSafeEntries(stackNames, key: "toolchains.stacks")

        let toolchains = KinhinConfig.ToolchainsConfig(
            specs: partial.specs != nil ? specs : nil,
            brew: partial.brew != nil ? brew : nil,
            stacks: partial.stacks != nil ? stackNames : nil
        )

        // Stack ids must be known, and their runtime prerequisites must be
        // explicitly selected. Unknown specs/brew entries stay legal (pass-
        // through); stacks are kinhin-curated so an unknown id is a typo.
        var resolvedStacks: [ToolchainStack] = []
        for name in stackNames {
            let (id, _) = ToolchainStack.splitSpec(name)
            guard let stack = ToolchainCatalog.stack(id: id) else {
                throw ConfigError.invalid(
                    "toolchains.stacks: unknown stack '\(id)' (known: \(ToolchainCatalog.stacks.map(\.id).joined(separator: ", ")))"
                )
            }
            resolvedStacks.append(stack)
        }

        // No implicit installs: each stack's runtime requirements must be
        // selected explicitly. `dotnet` in specs is the C#/.NET toolchain;
        // `node` covers every node-family entry.
        let specRoots = Set(specs.map { ToolchainCatalog.rootTool(of: $0) })
        for stack in resolvedStacks {
            for requirement in stack.requires {
                guard specRoots.contains(requirement.toolID) else {
                    throw ConfigError.invalid(
                        "toolchains: stack '\(stack.id)' requires \(requirement.rawValue) — add it to toolchains.specs (e.g. \"\(requirement.example)\")"
                    )
                }
            }
        }

        // Same no-implicit-installs rule for individual tools that need a
        // runtime (pnpm, yarn, playwright, cypress, netlify-cli, …).
        for spec in specs {
            let root = ToolchainCatalog.rootTool(of: spec)
            guard let tool = ToolchainCatalog.tool(id: root), !tool.requires.isEmpty else { continue }
            for requirement in tool.requires {
                guard specRoots.contains(requirement.toolID) else {
                    throw ConfigError.invalid(
                        "toolchains: '\(root)' requires \(requirement.rawValue) — add it to toolchains.specs (e.g. \"\(requirement.example)\")"
                    )
                }
            }
        }

        return toolchains
    }

    /// Shared list parsing: every entry non-empty, no duplicates, list must
    /// not be all-whitespace. Returns [] for an absent list.
    static func parseList(_ raw: [String]?, key: String) throws -> [String] {
        guard let raw else { return [] }
        var seen = Set<String>()
        for entry in raw {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ConfigError.invalid("\(key) entries must not be empty")
            }
            guard seen.insert(trimmed).inserted else {
                throw ConfigError.invalid("\(key): duplicate entry '\(trimmed)'")
            }
        }
        return raw
    }

    static func requireSafeEntries(_ entries: [String], key: String) throws {
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSafeToolchainEntry(trimmed) else {
                throw ConfigError.invalid(
                    "\(key): '\(trimmed)' contains characters that are not allowed (letters, digits and . _ + : / @ = ~ ^ * , - only; no leading '-')"
                )
            }
        }
    }

    /// Allowlist for toolchain entries (`node@22`, `ubi:owner/repo`, `npm:@scope/pkg`,
    /// `homebrew/cask/foo`). Everything else is refused rather than escaped.
    static func isSafeToolchainEntry(_ entry: String) -> Bool {
        entry.range(of: #"^[A-Za-z0-9_][A-Za-z0-9._+:/@=~^*,-]*$"#, options: .regularExpression) != nil
    }
}
