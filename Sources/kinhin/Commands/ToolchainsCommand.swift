import Foundation
import KinhinKit

/// `kinhin toolchains` — discovery for the managed-toolchain feature: the
/// curated catalog (tools + stacks), the current config's selections, the
/// shared-cache state, and the manual `prune` subcommand.
enum ToolchainsCommand {
    static func run(_ args: [String]) async {
        if hasFlag("--json", in: args) {
            print(jsonSummary())
            return
        }

        // Cache size (advisory; never fail the command over it).
        let pruner = ToolchainCachePruner()
        let bytes = pruner.totalBytes()

        print("Managed toolchains")
        print("")

        // Current selections
        let cfg = try? ConfigLoader.load()
        let toolchains = cfg?.toolchains
        print("Selections (config.yaml `toolchains:` section)")
        if let toolchains {
            print(
                "  specs:        \((toolchains.specs ?? []).joined(separator: ", ").isEmpty ? "-" : (toolchains.specs ?? []).joined(separator: ", "))"
            )
            print(
                "  brew:         \((toolchains.brew ?? []).joined(separator: ", ").isEmpty ? "-" : (toolchains.brew ?? []).joined(separator: ", "))"
            )
            print(
                "  stacks:       \((toolchains.stacks ?? []).joined(separator: ", ").isEmpty ? "-" : (toolchains.stacks ?? []).joined(separator: ", "))"
            )
            let shareCacheOn = toolchains.shareCache ?? false
            if shareCacheOn {
                let mounts = effectiveRuntimeMounts(hasContainer: cfg?.container != nil, hasDocker: cfg?.docker != nil)
                print("  share_cache:  yes — mounts at runtime into:")
                for mount in mounts {
                    print("    \(mount)")
                }
            } else {
                print("  share_cache:  no (add `share_cache: true` to share; baked installs always use the cache)")
            }
            let policy = ToolchainCachePolicy(from: toolchains)
            print(
                "  cache:        auto_prune: \(policy.autoPrune ? "on" : "off"), max_age_days: \(policy.maxAgeDays), max_gb: \(policy.maxGB)"
            )
        } else {
            print("  none configured — add a `toolchains:` section to config.yaml (see below)")
        }
        print("")

        // Catalog: stacks
        print("Stacks (curated recipes — each installs only its own pieces)")
        for stack in ToolchainCatalog.stacks {
            let reqs =
                stack.requires.isEmpty ? "" : " · requires: \(stack.requires.map(\.rawValue).joined(separator: ", "))"
            print("  \(stack.id.padding(toLength: 14, withPad: " ", startingAt: 0)) \(stack.summary)\(reqs)")
        }
        print("")

        // Catalog: tools
        print("Tools (mise by default; unknown specs pass through — this list is advisory)")
        for tool in ToolchainCatalog.tools {
            let reqs =
                tool.requires.isEmpty ? "" : " · requires: \(tool.requires.map(\.rawValue).joined(separator: ", "))"
            print("  \(tool.id.padding(toLength: 14, withPad: " ", startingAt: 0)) \(tool.summary)\(reqs)")
        }
        print("")

        print(
            "Shared cache: \(Paths.toolchainCache.path) (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))"
        )
        print("Prune manually: kinhin toolchains prune [--dry-run]")
        print("")
        print("Example config:")
        print(
            """
              toolchains:
                specs: ["node@22", "pnpm"]
                brew: ["yamllint"]
                stacks: ["flutter@3.24.0", "vercel"]
                share_cache: false
                cache:
                  auto_prune: true
                  max_age_days: 30
                  max_gb: 50
            """)
        print("")
        print("Wire it up: set the section, then `kinhin image prepare` (bakes the tools into the base image).")
    }

    /// The runtime-specific mount lines reflecting the effective wiring:
    /// prepare-time bakes always mount the cache; runner VMs/containers
    /// mount it per runtime when `share_cache` is on.
    static func effectiveRuntimeMounts(hasContainer: Bool, hasDocker: Bool) -> [String] {
        var lines = [
            "macOS VMs (tart): \(ToolchainCacheMount.guestPath) via virtiofs",
            "image prepares:   always mounted (VM + container bakes)",
        ]
        if hasContainer {
            lines.append("apple containers: \(ToolchainCacheMount.linuxGuestPath) via -v bind mount")
        }
        if hasDocker {
            lines.append("docker slots:     \(ToolchainCacheMount.linuxGuestPath) via -v bind mount")
        }
        return lines
    }

    /// `kinhin toolchains prune [--dry-run]`.
    static func prune(_ args: [String]) async {
        let dryRun = hasFlag("--dry-run", in: args)
        let cfg = try? ConfigLoader.load()
        let policy = ToolchainCachePolicy(from: cfg?.toolchains)
        // Manual prune always executes regardless of auto_prune (explicit
        // intent); --dry-run reports without touching anything.
        let report = ToolchainCachePruner().prune(policy: policy, dryRun: dryRun)
        if report.entries.isEmpty {
            print(dryRun ? "Nothing to prune." : "Cache is clean — nothing pruned.")
            return
        }
        print(dryRun ? "Would prune:" : "Pruned:")
        for entry in report.entries {
            print("  \(entry.path)  (\(ByteCountFormatter.string(fromByteCount: entry.freedBytes, countStyle: .file)))")
        }
        print(
            "\(dryRun ? "Would free" : "Freed") \(ByteCountFormatter.string(fromByteCount: report.freedBytes, countStyle: .file)) total."
        )
    }

    static func jsonSummary() -> String {
        let cfg = try? ConfigLoader.load()
        let policy = ToolchainCachePolicy(from: cfg?.toolchains)
        let bytes = ToolchainCachePruner().totalBytes()
        let dict: [String: Any] = [
            "selections": [
                "specs": cfg?.toolchains?.specs ?? [],
                "brew": cfg?.toolchains?.brew ?? [],
                "stacks": cfg?.toolchains?.stacks ?? [],
                "share_cache": cfg?.toolchains?.shareCache ?? false,
            ],
            "cache": [
                "path": Paths.toolchainCache.path,
                "bytes": bytes,
                "auto_prune": policy.autoPrune,
                "max_age_days": policy.maxAgeDays,
                "max_gb": policy.maxGB,
                "guest_path_macos": ToolchainCacheMount.guestPath,
                "guest_path_linux": ToolchainCacheMount.linuxGuestPath,
            ],
            "tools": ToolchainCatalog.tools.map { ["id": $0.id, "summary": $0.summary] },
            "stacks": ToolchainCatalog.stacks.map { ["id": $0.id, "summary": $0.summary] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .prettyPrinted]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }
}
