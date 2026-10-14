import Foundation
import KinhinKit

/// `kinhin toolchains` — discovery for per-project toolchains: each
/// project's declared toolchains, the curated catalog (tools + stacks), the
/// shared-cache state, the derived images, and the `prune` subcommand.
enum ToolchainsCommand {
    static func run(_ args: [String]) async {
        if hasFlag("--json", in: args) {
            print(jsonSummary())
            return
        }
        if let project = flag("--project", in: args) {
            await describeProject(project, ref: flag("--ref", in: args))
            return
        }

        // Cache size (advisory; never fail the command over it).
        let pruner = ToolchainCachePruner()
        let bytes = pruner.totalBytes()

        print("Toolchains (per project)")
        print("")

        // A broken config degrades to "no projects" rather than failing a
        // purely informational command; `kinhin config` commands surface
        // the real parse error.
        let cfg = try? ConfigLoader.load()
        print("Projects (config.yaml `projects:` section)")
        if let projects = cfg?.projects, !projects.isEmpty {
            for project in projects {
                print("  \(project.pattern)")
                if project.repoFile {
                    print("    versions:     from .kinhin.yml in the repo at each job's branch/tag")
                }
                if let toolchains = project.toolchains {
                    print("    toolchains:   \(summary(of: toolchains))")
                }
                print("    share_cache:  \(project.shareCache == true ? "yes" : "no")")
            }
        } else {
            print("  none configured — every repo gets the plain base image (see below)")
        }
        let policy = ToolchainCachePolicy(from: cfg?.toolchainCache)
        print(
            "  cache:        auto_prune: \(policy.autoPrune ? "on" : "off"), max_age_days: \(policy.maxAgeDays), max_gb: \(policy.maxGB)"
        )
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
        print("Tools (mise by default; a repo's .kinhin.yml may only name tools in this list)")
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
        print("Every project declares its own toolchains. In config.yaml:")
        print(
            """
              projects:
                - pattern: acme/api          # or acme/* for every repo of an owner
                  repo_file: true            # read .kinhin.yml in the repo at each job's ref
                - pattern: acme/web
                  toolchains:
                    specs: ["node@22", "pnpm"]
                    stacks: ["vercel"]
            """)
        print("")
        print("and in the repo's .kinhin.yml:")
        print(
            """
              toolchains:
                specs: ["go@1.22.5", "node@20"]
            """)
        print("")
        print("Preview a repo: kinhin toolchains --project acme/api [--ref main]")
        print("Bake it now:    kinhin image prepare --project acme/api [--ref main]")
        print("")
        print("Per job: every prepared image also carries `kinhin-toolchain`, so a workflow step can install")
        print("only what it needs (`run: kinhin-toolchain install node@22 pnpm`). Inspect: kinhin toolchains helper")
    }

    static func summary(of toolchains: KinhinConfig.ToolchainsConfig) -> String {
        let parts =
            (toolchains.specs ?? []) + (toolchains.brew ?? []).map { "brew:\($0)" }
            + (toolchains.stacks ?? []).map { "stack:\($0)" }
        return parts.isEmpty ? "-" : parts.joined(separator: ", ")
    }

    /// `kinhin toolchains --project owner/name [--ref X]`.
    static func describeProject(_ project: String, ref: String?) async {
        do {
            let cfg = try ConfigLoader.load()
            let tart = try TartController(configuredPath: cfg.tartPath)
            let result = try await ProjectImageService(config: cfg, tart: tart).describe(repository: project, ref: ref)
            print("repository:  \(result.repository)")
            print("source:      \(result.source)")
            print("toolchains:  \(result.summary.isEmpty ? "-" : result.summary)")
            print("image:       \(result.imageName ?? "base image (nothing to bake)")")
            if let warning = result.warning { warn(warning) }
        } catch {
            fail(error)
        }
    }

    /// `kinhin toolchains list-images`.
    static func listImages() async {
        let records = ProjectImageStore().all.sorted { $0.lastUsedAt > $1.lastUsedAt }
        guard !records.isEmpty else {
            print("No derived project images.")
            return
        }
        // Sizes are cosmetic, but they must come from the fleet's tart:
        // honor `tart_path:` like every other tart call. A config or tart
        // that fails costs the sizes (with a warning), never the listing.
        var sizes: [String: Int]?
        do {
            let tartPath = try loadConfigIfPresent()?.tartPath
            sizes = try await TartController(configuredPath: tartPath).list().reduce(into: [String: Int]()) {
                $0[$1.name] = $1.diskGB
            }
        } catch {
            warn("could not list tart images (\(error.localizedDescription)); sizes are not shown")
        }
        for record in records {
            let size = sizeLabel(record.name, sizes: sizes)
            let used = record.lastUsedAt.formatted(date: .abbreviated, time: .shortened)
            print("\(record.name)  \(record.summary)  [\(size)] last used \(used)")
        }
    }

    /// One derived image's size column: its disk size, "not on disk", or
    /// "size unknown" when tart could not be listed (`sizes` nil) — never
    /// "not on disk" for an image that may well be there.
    static func sizeLabel(_ name: String, sizes: [String: Int]?) -> String {
        guard let sizes else { return "size unknown" }
        return sizes[name].map { "\($0) GB disk" } ?? "not on disk"
    }

    /// `kinhin toolchains helper [--linux]`: the per-job helper script as
    /// `image prepare` bakes it, for auditing (stdout only).
    static func helper(_ args: [String]) {
        print(ToolchainCatalog.helperScript(for: hasFlag("--linux", in: args) ? .linux : .macOS), terminator: "")
    }

    /// `kinhin toolchains prune [--dry-run]`.
    static func prune(_ args: [String]) async {
        let dryRun = hasFlag("--dry-run", in: args)
        // No config means the default prune policy; a broken one fails the
        // prune instead of deleting by a policy the user did not write.
        let cfg: KinhinConfig?
        do {
            cfg = try loadConfigIfPresent()
        } catch {
            fail(error)
        }
        let policy = ToolchainCachePolicy(from: cfg?.toolchainCache)
        // Manual prune always executes regardless of auto_prune (explicit
        // intent); --dry-run reports without touching anything.
        let report = ToolchainCachePruner().prune(policy: policy, dryRun: dryRun)
        await pruneImages(dryRun: dryRun, config: cfg)
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

    /// Derived images beyond `max_project_images` or unused for the cache's
    /// age limit.
    static func pruneImages(dryRun: Bool, config: KinhinConfig?) async {
        let inUse = Set(FleetStore().all.compactMap(\.image))
        let candidates = ProjectImageService.pruneCandidates(config: config, inUse: inUse)
        guard !candidates.isEmpty else { return }
        if dryRun {
            print("Would delete derived images: \(candidates.joined(separator: ", "))")
            return
        }
        guard let config else { return }
        do {
            let tart = try TartController(configuredPath: config.tartPath)
            let removed = await ProjectImageService.prune(config: config, tart: tart, inUse: inUse)
            print("Deleted derived images: \(removed.isEmpty ? "none" : removed.joined(separator: ", "))")
        } catch {
            warn("could not prune derived images: \(error.localizedDescription)")
        }
    }

    static func jsonSummary() -> String {
        // A broken config degrades to defaults in this JSON document (the
        // doctor's JSON embeds the same config error separately).
        let cfg = try? ConfigLoader.load()
        let policy = ToolchainCachePolicy(from: cfg?.toolchainCache)
        let bytes = ToolchainCachePruner().totalBytes()
        let projects: [[String: Any]] = (cfg?.projects ?? []).map { project in
            [
                "pattern": project.pattern,
                "repo_file": project.repoFile,
                "specs": project.toolchains?.specs ?? [],
                "brew": project.toolchains?.brew ?? [],
                "stacks": project.toolchains?.stacks ?? [],
                "share_cache": project.shareCache ?? false,
            ]
        }
        let images: [[String: Any]] = ProjectImageStore().all.map {
            ["name": $0.name, "summary": $0.summary, "last_used": ISO8601DateFormatter().string(from: $0.lastUsedAt)]
        }
        let dict: [String: Any] = [
            "projects": projects,
            "images": images,
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
        // `dict` holds only strings, numbers, arrays and dictionaries, so serialization cannot fail.
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .prettyPrinted]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }
}
