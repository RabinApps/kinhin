import Foundation

/// What `kinhin cleanup` (and the "everything" reset scope) reclaim from the
/// Mac: leftover runner VMs, leftover image-build scratch VMs, baked images
/// and the shared toolchain cache. Building the plan never deletes anything;
/// `execute` does. Lives in KinhinKit so both the CLI command and
/// `ResetEverything` share one enumeration and one deletion order.
public struct CleanupPlan: Equatable, Sendable {
    /// Runner VMs (`kinhin-*`, or the pre-rename `orchard-*`) tart still holds.
    public var vms: [String] = []
    /// Leftover image-build scratch VMs (`kinhin-prepare-tmp-*`) from a
    /// crashed or killed bake.
    public var scratchVMs: [String] = []
    /// The configured base image and any named `images:` entries that exist
    /// locally and were requested.
    public var images: [String] = []
    /// Whether to empty the toolchain cache, and how many bytes it holds.
    public var cacheBytes: Int64?

    public init(vms: [String] = [], scratchVMs: [String] = [], images: [String] = [], cacheBytes: Int64? = nil) {
        self.vms = vms
        self.scratchVMs = scratchVMs
        self.images = images
        self.cacheBytes = cacheBytes
    }

    public var isEmpty: Bool { vms.isEmpty && scratchVMs.isEmpty && images.isEmpty && cacheBytes == nil }

    /// Which groups to include when planning. All false plans nothing —
    /// callers that mean "everything" use `.all`.
    public struct Targets: Equatable, Sendable {
        public var vms = false
        public var image = false
        public var cache = false

        public init(vms: Bool = false, image: Bool = false, cache: Bool = false) {
            self.vms = vms
            self.image = image
            self.cache = cache
        }

        public static var all: Targets { Targets(vms: true, image: true, cache: true) }
    }

    /// Enumerates what the requested groups would reclaim. Never deletes.
    /// `tart` nil (binary missing, or a broken config) contributes no VMs or
    /// images; the cache is still counted.
    public static func plan(
        targets: Targets,
        tart: (any TartControlling)?,
        baseImage: String,
        namedImages: [String] = [],
        cacheRoot: URL
    ) async throws -> CleanupPlan {
        var plan = CleanupPlan()
        // Named `images:` entries are baked tart images too: they are never
        // runner VMs, and image targeting offers them alongside the base image.
        let baked = [baseImage] + namedImages
        if targets.vms || targets.image, let tart {
            let local = try await tart.list()
            if targets.vms {
                let ours = local.map(\.name)
                    .filter { InstanceNaming.isOurs($0) && !baked.contains($0) }
                    .sorted()
                // Build scratch VMs (`kinhin-prepare-tmp-*`) get their own
                // line: they are leftovers from a crashed or killed bake, not
                // runner VMs.
                plan.scratchVMs = ours.filter { $0.hasPrefix(ImagePreparer.scratchPrefix) }
                plan.vms = ours.filter { !plan.scratchVMs.contains($0) }
            }
            if targets.image {
                plan.images = baked.filter { name in local.contains(where: { $0.name == name }) }
            }
        }
        if targets.cache {
            // Not the pruner's total: it skips entries touched in the last hour, and this wants everything.
            let bytes = directoryBytes(cacheRoot)
            if bytes > 0 { plan.cacheBytes = bytes }
        }
        return plan
    }

    /// The confirmation text: one line per group, "would remove" until
    /// `willDelete` flips the wording for the real run.
    public func describe(willDelete: Bool) -> String {
        let verb = willDelete ? "removing" : "would remove"
        var lines: [String] = []
        if !vms.isEmpty {
            lines.append("\(verb) \(vms.count) runner VM(s): \(vms.joined(separator: ", "))")
        }
        if !scratchVMs.isEmpty {
            lines.append(
                "\(verb) \(scratchVMs.count) leftover image-build scratch VM(s): "
                    + "\(scratchVMs.joined(separator: ", ")) (from a crashed or killed bake)")
        }
        if !images.isEmpty {
            lines.append(
                "\(verb) image(s): \(images.joined(separator: ", ")) (re-create them with `kinhin image prepare`)")
        }
        if let bytes = cacheBytes {
            lines.append(
                "\(verb) the toolchain cache (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))")
        }
        return lines.joined(separator: "\n")
    }

    /// Deletes everything the plan listed. A running VM is stopped first (a
    /// stopped one is fine); the cache is emptied but its directory kept
    /// (guests mount the directory itself).
    public func execute(tart: (any TartControlling)?, cacheRoot: URL) async throws {
        if let tart {
            for vm in vms + scratchVMs {
                // Not running (or already stopped) is exactly what we want.
                try? await tart.stop(name: vm)
                try await tart.delete(name: vm)
            }
            if !images.isEmpty {
                for image in images { try await tart.delete(name: image) }
            }
        }
        if cacheBytes != nil {
            let entries = try FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)
            for entry in entries { try FileManager.default.removeItem(at: entry) }
        }
    }

    /// Recursive byte total of regular files under `root`.
    static func directoryBytes(_ root: URL) -> Int64 {
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
