import Foundation

/// What `kinhin image prune` removes in one confirmed pass: every stale
/// derived-image record (the index remembers an image tart no longer has)
/// and every installed image nothing uses — no runner is on it and no config
/// names it. Building the plan never deletes anything; `execute` runs the
/// exact code path `kinhin image delete` executes. Configured images (base,
/// named, derived), anything a `base_image:` points at, and images runners
/// are using are never candidates, so a sweep cannot take the fleet's images
/// away — and a runtime whose images could not be listed is skipped, never
/// guessed at.
public struct ImagePrunePlan: Sendable, Equatable {
    /// A local image kept because runners are on it right now — listed in
    /// the report so "why is this one still here?" answers itself.
    public struct InUse: Sendable, Equatable {
        public let name: String
        public let runtime: ImageInventory.Runtime
        public let runners: [String]

        public init(name: String, runtime: ImageInventory.Runtime, runners: [String]) {
            self.name = name
            self.runtime = runtime
            self.runners = runners
        }
    }

    /// What goes: stale index records (`present == false`) and unused local
    /// images — the delete plan's own target shape, so executing is one
    /// shared implementation instead of a second deletion path.
    public let targets: [ImageDeletePlan.Target]
    /// Unused-looking images kept because a runner is using them.
    public let inUse: [InUse]
    /// Runtimes whose images could not be listed → why this pass skips them.
    public let unavailable: [String: String]

    public var isEmpty: Bool { targets.isEmpty }

    /// Whole GB the present targets occupy; nil when no target reported a
    /// size — the report then omits the estimate instead of guessing zero.
    public var reclaimGB: Int? {
        let sizes = targets.filter(\.present).compactMap(\.sizeGB)
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    public init(targets: [ImageDeletePlan.Target], inUse: [InUse], unavailable: [String: String]) {
        self.targets = targets
        self.inUse = inUse
        self.unavailable = unavailable
    }

    /// Selects the sweep from an inventory. Role does most of the work:
    /// only `local` images are candidates (base/named/derived are configured,
    /// stale records are swept by their `stale` flag) and only when nothing
    /// uses them. The config's names are protected flat across runtimes —
    /// `base_image:` may name any local VM, and a local OCI image may be the
    /// base the next bake pulls from, so "the config names it" beats role.
    public static func plan(
        inventory: ImageInventory, config: KinhinConfig?, fleet: [VMRecord] = []
    ) -> ImagePrunePlan {
        let protected = protectedNames(config)
        var targets: [ImageDeletePlan.Target] = []
        var inUse: [InUse] = []
        for entry in inventory.entries {
            if entry.stale {
                // A live VM still answers to this name; keep the record.
                if fleet.contains(where: { $0.image == entry.name }) { continue }
                targets.append(
                    ImageDeletePlan.Target(
                        name: entry.name, runtime: entry.runtime, role: entry.role,
                        present: false, stale: true))
                continue
            }
            guard entry.present, entry.role == .local, !protected.contains(entry.name) else { continue }
            if !entry.usedBy.isEmpty {
                inUse.append(InUse(name: entry.name, runtime: entry.runtime, runners: entry.usedBy))
                continue
            }
            targets.append(
                ImageDeletePlan.Target(
                    name: entry.name, runtime: entry.runtime, role: entry.role,
                    present: true, sizeGB: entry.sizeGB))
        }
        var unavailable: [String: String] = [:]
        for section in inventory.sections {
            if let reason = section.unavailable { unavailable[section.runtime.rawValue] = reason }
        }
        return ImagePrunePlan(targets: targets, inUse: inUse, unavailable: unavailable)
    }

    /// Every name the config cares about: the configured images themselves
    /// plus every `base_image:` (top-level, per-image, container, docker).
    private static func protectedNames(_ config: KinhinConfig?) -> Set<String> {
        guard let config else { return [] }
        var names: Set<String> = [config.image]
        names.formUnion(config.images.map(\.name))
        if let base = config.baseImage { names.insert(base) }
        if let container = config.container {
            if let base = container.baseImage { names.insert(base) }
            names.insert(container.image)
        }
        if let docker = config.docker {
            if let base = docker.baseImage { names.insert(base) }
            names.insert(docker.image)
        }
        names.formUnion(config.images.compactMap(\.baseImage))
        return names
    }

    /// The shared delete path: present targets go to their runtime, derived
    /// records lose their index entry (and a derived image deleted on disk
    /// loses its record too, so the index never goes stale behind the
    /// user's back).
    public func execute(
        tart: (any TartControlling)?,
        container: AppleContainerRuntime?,
        docker: DockerRuntime?,
        store: ProjectImageStore = ProjectImageStore()
    ) async throws {
        try await ImageDeletePlan(targets: targets, refusals: [])
            .execute(tart: tart, container: container, docker: docker, store: store)
    }
}
