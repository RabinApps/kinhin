import Foundation

/// What `kinhin image delete` will and will not remove: one target per
/// (name, runtime) where the image is installed, plus a refusal for every
/// name that cannot go (unknown, a runner VM, or in use). Building the plan
/// never deletes anything; `execute` does. Shares the cleanup contract:
/// nothing is touched while the caller still asks for confirmation.
public struct ImageDeletePlan: Sendable, Equatable {
    /// One installed image (or stale index entry) the delete will remove.
    public struct Target: Sendable, Equatable {
        public let name: String
        public let runtime: ImageInventory.Runtime
        public let role: ImageInventory.Role
        public let present: Bool
        /// A derived-image record whose tart image is already gone: only the
        /// index entry is removed.
        public let stale: Bool
        /// What the image occupies on disk (inventory sizes; nil when the
        /// runtime reported none). Set by the prune plan so its report can
        /// estimate the space a sweep frees.
        public let sizeGB: Int?

        public init(
            name: String, runtime: ImageInventory.Runtime, role: ImageInventory.Role, present: Bool,
            stale: Bool = false, sizeGB: Int? = nil
        ) {
            self.name = name
            self.runtime = runtime
            self.role = role
            self.present = present
            self.stale = stale
            self.sizeGB = sizeGB
        }
    }

    /// A requested name the delete refuses, with the reason to show and the
    /// class of problem (the CLI maps it to an exit code).
    public struct Refusal: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// Nothing of that name is installed.
            case unknown
            /// The name is a runner VM or a bake scratch VM, not an image.
            case notAnImage
            /// Something is running from the image right now.
            case inUse
        }

        public let name: String
        public let kind: Kind
        public let reason: String

        public init(name: String, kind: Kind, reason: String) {
            self.name = name
            self.kind = kind
            self.reason = reason
        }
    }

    public let targets: [Target]
    public let refusals: [Refusal]

    public var isEmpty: Bool { targets.isEmpty }

    public init(targets: [Target], refusals: [Refusal]) {
        self.targets = targets
        self.refusals = refusals
    }

    /// Resolves the requested names against the inventory. Every name is
    /// either covered by targets or by refusals, so the caller can refuse the
    /// whole run before deleting anything (`refusals` first, always).
    public static func plan(
        names: [String], inventory: ImageInventory, fleet: [VMRecord] = []
    ) -> ImageDeletePlan {
        var seen = Set<String>()
        var targets: [Target] = []
        var refusals: [Refusal] = []
        for name in names where seen.insert(name).inserted {
            let matches = inventory.entries.filter { $0.name == name && ($0.present || $0.stale) }
            if !matches.isEmpty {
                let users = matches.flatMap(\.usedBy).sorted()
                if !users.isEmpty {
                    refusals.append(
                        Refusal(
                            name: name, kind: .inUse,
                            reason:
                                "'\(name)' is in use by \(users.count) runner(s): \(users.joined(separator: ", "))"
                                + " — stop the fleet first: kinhin stop"))
                    continue
                }
                targets += matches.map {
                    Target(
                        name: $0.name, runtime: $0.runtime, role: $0.role, present: $0.present, stale: $0.stale)
                }
                continue
            }
            if let reason = notAnImageReason(name, inventory: inventory, fleet: fleet) {
                refusals.append(Refusal(name: name, kind: .notAnImage, reason: reason))
                continue
            }
            refusals.append(
                Refusal(
                    name: name, kind: .unknown,
                    reason:
                        "no installed image named '\(name)'"
                        + suggestion(name, in: inventory)
                        + " — run `kinhin image list` to see what is installed"))
        }
        return ImageDeletePlan(targets: targets, refusals: refusals)
    }

    /// Why this name is not an image at all (nil = it is not a known VM
    /// either, so the name is simply unknown).
    private static func notAnImageReason(_ name: String, inventory: ImageInventory, fleet: [VMRecord]) -> String? {
        if fleet.contains(where: { $0.id == name }) {
            return "'\(name)' is a runner VM, not an image — remove it with `kinhin cleanup --vms`"
        }
        if name.hasPrefix(ImagePreparer.scratchPrefix) {
            return "'\(name)' is a leftover image-build scratch VM (from a crashed or killed bake)"
                + " — remove it with `kinhin cleanup --vms`"
        }
        if !inventory.presentNames.contains(name),
            name.hasPrefix("kinhin-") || name.hasPrefix("orchard-")
        {
            return "'\(name)' is a runner VM, not an image — remove it with `kinhin cleanup --vms`"
        }
        return nil
    }

    /// "did you mean …" for a name that is not installed, from the names the
    /// inventory does hold (substring matches only — cheap and predictable).
    private static func suggestion(_ name: String, in inventory: ImageInventory) -> String {
        let close = inventory.presentNames.filter {
            $0 != name && ($0.hasPrefix(name) || name.hasPrefix($0) || $0.contains(name) || name.contains($0))
        }.sorted()
        guard !close.isEmpty else { return "" }
        let shown = close.prefix(3).joined(separator: ", ")
        return close.count > 3 ? " (did you mean: \(shown), …?)" : " (did you mean: \(shown)?)"
    }

    /// Deletes every target. A stale derived record only loses its index
    /// entry (there is no image left to delete); a derived image that is
    /// deleted on disk also loses its record, so the index never goes stale
    /// behind the user's back. The first failure stops the run.
    public func execute(
        tart: (any TartControlling)?,
        container: AppleContainerRuntime?,
        docker: DockerRuntime?,
        store: ProjectImageStore = ProjectImageStore()
    ) async throws {
        for target in targets {
            if target.present {
                switch target.runtime {
                case .tart:
                    guard let tart else {
                        throw ImageError.runtimeUnavailable(
                            "tart is not installed — install it first: \(TartHealthProbe.installCommand)")
                    }
                    try await tart.delete(name: target.name)
                case .container:
                    guard let container else {
                        throw ImageError.runtimeUnavailable(
                            "the container CLI is not available — brew install container && container system start --enable-kernel-install"
                        )
                    }
                    try await container.deleteImage(named: target.name)
                case .docker:
                    guard let docker else {
                        throw ImageError.runtimeUnavailable(
                            "docker is not available — install Docker Desktop or: brew install colima && colima start")
                    }
                    try await docker.deleteImage(named: target.name)
                }
            }
            if target.role == .derived {
                store.remove(name: target.name)
            }
        }
    }
}
