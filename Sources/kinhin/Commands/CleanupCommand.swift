import Foundation
import KinhinKit

/// `kinhin cleanup` — reclaims what kinhin leaves on the Mac: leftover runner
/// VMs, the baked base image and the shared toolchain cache. Nothing is deleted
/// without `--yes`; without it the command only reports what it would remove.
enum CleanupCommand {
    struct Plan: Equatable {
        /// Runner VMs (`kinhin-*`, or the pre-rename `orchard-*`) tart still holds.
        var vms: [String] = []
        /// Leftover image-build scratch VMs (`kinhin-prepare-tmp-*`) from a
        /// crashed or killed bake.
        var scratchVMs: [String] = []
        /// The configured base image and any named `images:` entries, when they
        /// exist locally and `--image` was given.
        var images: [String] = []
        /// Whether to empty the toolchain cache, and how many bytes it holds.
        var cacheBytes: Int64?

        var isEmpty: Bool { vms.isEmpty && scratchVMs.isEmpty && images.isEmpty && cacheBytes == nil }
    }

    struct Selection: Equatable {
        var vms = false
        var image = false
        var cache = false

        init(args: [String]) {
            let all = hasFlag("--all", in: args)
            vms = all || hasFlag("--vms", in: args)
            image = all || hasFlag("--image", in: args)
            cache = all || hasFlag("--cache", in: args)
            // Bare `kinhin cleanup` looks at everything (a report only; it deletes nothing).
            if !vms && !image && !cache { self = Selection(all: true) }
        }

        private init(all: Bool) {
            vms = all
            image = all
            cache = all
        }
    }

    static func run(_ args: [String]) async throws {
        let selection = Selection(args: args)
        let confirmed = hasFlag("--yes", in: args)
        // Cleanup must work even when the config is broken (that may be why it
        // is being run), so a broken config degrades to the default — but it
        // says so, instead of silently guessing which images are configured.
        let config: KinhinConfig
        do {
            config = try ConfigLoader.load()
        } catch {
            warn("could not read the config (\(error.localizedDescription)); only the default image name is considered")
            config = KinhinConfig.default
        }
        let tart = try? TartController(configuredPath: config.tartPath)
        let plan = try await makePlan(
            selection: selection, tart: tart, baseImage: config.image,
            namedImages: config.images.map(\.name), cacheRoot: Paths.toolchainCache)

        if plan.isEmpty {
            print("nothing to clean up")
            return
        }
        print(describe(plan, willDelete: confirmed))
        guard confirmed else {
            print("")
            print("nothing was deleted; re-run with --yes to remove the above (stop the fleet first: kinhin stop)")
            return
        }
        try await execute(plan, tart: tart, cacheRoot: Paths.toolchainCache)
        print("done")
    }

    static func makePlan(
        selection: Selection, tart: (any TartControlling)?, baseImage: String, namedImages: [String] = [],
        cacheRoot: URL
    ) async throws -> Plan {
        var plan = Plan()
        // Named `images:` entries are baked tart images too: they are never
        // runner VMs, and `--image` offers them alongside the base image.
        let baked = [baseImage] + namedImages
        if selection.vms || selection.image, let tart {
            let local = try await tart.list()
            if selection.vms {
                let ours = local.map(\.name)
                    .filter { ($0.hasPrefix("kinhin-") || $0.hasPrefix("orchard-")) && !baked.contains($0) }
                    .sorted()
                // Build scratch VMs (`kinhin-prepare-tmp-*`) get their own
                // line: they are leftovers from a crashed or killed bake, not
                // runner VMs.
                plan.scratchVMs = ours.filter { $0.hasPrefix(ImagePreparer.scratchPrefix) }
                plan.vms = ours.filter { !plan.scratchVMs.contains($0) }
            }
            if selection.image {
                plan.images = baked.filter { name in local.contains(where: { $0.name == name }) }
            }
        }
        if selection.cache {
            // Not the pruner's total: it skips entries touched in the last hour, and this wants everything.
            let bytes = directoryBytes(cacheRoot)
            if bytes > 0 { plan.cacheBytes = bytes }
        }
        return plan
    }

    static func describe(_ plan: Plan, willDelete: Bool) -> String {
        let verb = willDelete ? "removing" : "would remove"
        var lines: [String] = []
        if !plan.vms.isEmpty {
            lines.append("\(verb) \(plan.vms.count) runner VM(s): \(plan.vms.joined(separator: ", "))")
        }
        if !plan.scratchVMs.isEmpty {
            lines.append(
                "\(verb) \(plan.scratchVMs.count) leftover image-build scratch VM(s): "
                    + "\(plan.scratchVMs.joined(separator: ", ")) (from a crashed or killed bake)")
        }
        if !plan.images.isEmpty {
            lines.append(
                "\(verb) image(s): \(plan.images.joined(separator: ", ")) (re-create them with `kinhin image prepare`)")
        }
        if let bytes = plan.cacheBytes {
            lines.append(
                "\(verb) the toolchain cache (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))")
        }
        return lines.joined(separator: "\n")
    }

    static func execute(_ plan: Plan, tart: (any TartControlling)?, cacheRoot: URL) async throws {
        if let tart {
            for vm in plan.vms + plan.scratchVMs {
                // A running VM must be stopped before tart will delete it; an already-stopped one is fine.
                try? await tart.stop(name: vm)  // not running (or already stopped) is exactly what we want
                try await tart.delete(name: vm)
            }
            if !plan.images.isEmpty {
                for image in plan.images { try await tart.delete(name: image) }
            }
        }
        if plan.cacheBytes != nil {
            // Remove the contents, not the directory itself: guests mount it.
            let entries = try FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)
            for entry in entries { try FileManager.default.removeItem(at: entry) }
        }
    }

    private static func directoryBytes(_ root: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            // An entry that vanishes mid-walk simply does not count.
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
