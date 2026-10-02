import Foundation

/// Turns raw probe hits into catalog specs: drops what the catalog cannot
/// install, picks versions by precedence, cleans them, adds the runtimes the
/// loader requires, and sorts for stable output.
enum ToolchainNormalizer {
    private struct Key: Hashable {
        let id: String
        let isStack: Bool
    }

    /// Ranges keep only the major version for these; everything else keeps major.minor.
    private static let majorOnly: Set<String> = ["node", "java", "bun", "deno"]

    static func normalize(_ hits: [ToolchainHit]) -> ToolchainDetection {
        var order: [Key] = []
        var grouped: [Key: [ToolchainHit]] = [:]
        var unmatched: [String] = []
        for hit in hits {
            let key = Key(id: hit.id, isStack: hit.isStack)
            let known =
                hit.isStack ? ToolchainCatalog.stack(id: hit.id) != nil : ToolchainCatalog.tool(id: hit.id) != nil
            guard known else {
                if !unmatched.contains(hit.id) { unmatched.append(hit.id) }
                continue
            }
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(hit)
        }

        var specs: [String: String] = [:]  // tool id → spec
        var stacks: [String: String] = [:]
        var evidence: [ToolchainDetection.Finding] = []
        for key in order {
            // Highest-precedence hit that carries a usable version wins.
            let sorted = (grouped[key] ?? []).sorted { $0.precedence < $1.precedence }
            let version = sorted.lazy.compactMap { cleanVersion($0.version, tool: key.id) }.first
            let spec = key.isStack ? stackSpec(key.id, version) : toolSpec(key.id, version)
            if key.isStack { stacks[key.id] = spec } else { specs[key.id] = spec }
            evidence.append(
                contentsOf: sorted.map { .init(spec: spec, source: $0.source, reason: $0.reason) })
        }

        // No implicit installs: each entry's runtimes must be listed too.
        var required: [(runtime: String, by: String)] = []
        for id in specs.keys.sorted() {
            for requirement in ToolchainCatalog.tool(id: id)?.requires ?? [] {
                required.append((requirement.toolID, id))
            }
        }
        for id in stacks.keys.sorted() {
            for requirement in ToolchainCatalog.stack(id: id)?.requires ?? [] {
                required.append((requirement.toolID, id))
            }
        }
        for (runtime, by) in required where specs[runtime] == nil {
            let spec = toolSpec(runtime, nil)
            specs[runtime] = spec
            evidence.append(.init(spec: spec, source: "implied", reason: "required by \(by)"))
        }

        return ToolchainDetection(
            specs: specs.values.sorted(), stacks: stacks.values.sorted(),
            evidence: evidence.sorted { ($0.spec, $0.source) < ($1.spec, $1.source) },
            unmatched: unmatched.sorted(), recommendations: [])
    }

    // MARK: - Specs

    private static func toolSpec(_ id: String, _ version: String?) -> String {
        guard let tool = ToolchainCatalog.tool(id: id) else { return id }
        switch tool.installer {
        case .mise, .npm:
            if let version { return "\(id)@\(version)" }
            return tool.defaultSpec.isEmpty ? id : tool.defaultSpec
        default:
            // Homebrew, apt and gem entries take no @version.
            return id
        }
    }

    private static func stackSpec(_ id: String, _ version: String?) -> String {
        version.map { "\(id)@\($0)" } ?? id
    }

    // MARK: - Versions

    /// `v22.1.0` → `22.1.0`; `^20.1`, `>=20`, `~3.11.2` → a range floor (`20`, `20`, `3.11`);
    /// `20.x` → `20`; `lts/*`, expressions and anything unsafe → nil (catalog default).
    static func cleanVersion(_ raw: String?, tool: String) -> String? {
        guard var text = raw?.trimmed(), !text.isEmpty else { return nil }
        let lowered = text.lowercased()
        if lowered.hasPrefix("lts") || lowered == "latest" || lowered == "*" || lowered == "node" { return nil }
        // Only the first clause of "a || b" or ">=a <b".
        text = String(text.split(whereSeparator: { " ,|".contains($0) }).first ?? "")
        var isRange = false
        while let first = text.first, "^~>=<".contains(first) {
            text.removeFirst()
            isRange = true
        }
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        var parts = text.split(separator: ".").map(String.init)
        while let last = parts.last, ["x", "X", "*"].contains(last) {
            parts.removeLast()
            isRange = true
        }
        guard !parts.isEmpty else { return nil }
        if isRange { parts = Array(parts.prefix(majorOnly.contains(tool) ? 1 : 2)) }
        let cleaned = parts.joined(separator: ".")
        // Same alphabet the loader's safety check allows for a version.
        guard cleaned.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else { return nil }
        return cleaned
    }
}
