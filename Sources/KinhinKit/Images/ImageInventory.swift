import Foundation

/// What `kinhin image list` shows: every image installed on this Mac for the
/// runtimes kinhin bakes for (tart VMs, apple container, Docker), annotated
/// with its role in the config, its size, who is using it, and the configured
/// images that are not built yet. `build` is the pure core (testable with
/// injected listings); `probe` gathers the real ones.
public struct ImageInventory: Sendable, Equatable, Codable {
    public enum Runtime: String, Codable, Sendable {
        case tart
        case container
        case docker
    }

    /// What the image is to kinhin. `base` and `named` come from the config
    /// (deleting them means re-baking), `derived` from the per-project image
    /// index, `local` is anything else the runtime holds.
    public enum Role: String, Codable, Sendable {
        case base
        case named
        case derived
        case local
    }

    public struct Entry: Sendable, Equatable, Codable {
        public let name: String
        public let runtime: Runtime
        public let role: Role
        /// false = the name comes from config or the derived-image index only:
        /// there is nothing on disk to delete yet.
        public let present: Bool
        /// A derived-image record whose tart image is gone — deleting it
        /// removes the stale index entry and nothing else.
        public let stale: Bool
        /// tart's `Source` column: what the entry was cloned from (tart only).
        public let source: String?
        public let sizeGB: Int?
        public let lastUsedAt: Date?
        /// What a derived image was baked with ("go@1.22.5, node@20").
        public let summary: String?
        /// Runner VM ids (tart) or container ids (Linux runtimes) using it.
        public let usedBy: [String]

        public init(
            name: String, runtime: Runtime, role: Role, present: Bool, stale: Bool = false,
            source: String? = nil, sizeGB: Int? = nil, lastUsedAt: Date? = nil, summary: String? = nil,
            usedBy: [String] = []
        ) {
            self.name = name
            self.runtime = runtime
            self.role = role
            self.present = present
            self.stale = stale
            self.source = source
            self.sizeGB = sizeGB
            self.lastUsedAt = lastUsedAt
            self.summary = summary
            self.usedBy = usedBy
        }
    }

    public struct Section: Sendable, Equatable, Codable {
        public let runtime: Runtime
        /// Why this runtime's images could not be listed; nil = they were.
        public let unavailable: String?
        /// Why the runtime's instances could not be listed, so no entry's
        /// `usedBy` can be trusted; nil = they were. Delete and prune never
        /// touch such a section's images: "nobody uses it" is unknown.
        public let usageUnknown: String?
        public let entries: [Entry]

        public init(runtime: Runtime, unavailable: String?, usageUnknown: String? = nil, entries: [Entry]) {
            self.runtime = runtime
            self.unavailable = unavailable
            self.usageUnknown = usageUnknown
            self.entries = entries
        }

        /// Total disk usage of this runtime's installed images, in GB — what
        /// makes bloat visible at a glance (`kinhin image list` prints it
        /// under the section title). nil when the runtime reported no sizes:
        /// then every row says "—" and a total would be a guess.
        public var totalGB: Int? {
            let sizes = entries.filter(\.present).compactMap(\.sizeGB)
            return sizes.isEmpty ? nil : sizes.reduce(0, +)
        }

        /// How many images are actually on disk (not configured-but-not-built).
        public var presentCount: Int { entries.filter(\.present).count }
    }

    /// One runtime's raw picture: what it lists, and why it could not list.
    public struct RuntimeImages: Sendable, Equatable {
        /// nil = the listing worked; a string = it did not, and says why.
        public let unavailable: String?
        public let names: [String]
        public let sizesGB: [String: Int]
        /// tart's `Source` column by name (tart listings only).
        public let sources: [String: String]
        /// Runner VM ids / container ids of this runtime.
        public let instances: [String]
        /// nil = `instances` is the real list; a string = listing them
        /// failed (and says why), so `instances` is empty but not "unused".
        public let usageUnknown: String?

        public init(
            unavailable: String? = nil, names: [String] = [], sizesGB: [String: Int] = [:],
            sources: [String: String] = [:], instances: [String] = [], usageUnknown: String? = nil
        ) {
            self.unavailable = unavailable
            self.names = names
            self.sizesGB = sizesGB
            self.sources = sources
            self.instances = instances
            self.usageUnknown = usageUnknown
        }

        /// The listing shape for tart's `list` output — name, source and
        /// size, everything the image rows reason over.
        public init(tartEntries: [TartVM], instances: [String] = []) {
            var sizes: [String: Int] = [:]
            var sources: [String: String] = [:]
            for vm in tartEntries {
                sources[vm.name] = vm.source
                // Allocated storage (sizeGB), falling back to the declared
                // capacity for a tart too old to report a size — virtual
                // capacity alone over-states freeable space.
                if let size = vm.sizeGB ?? vm.diskGB { sizes[vm.name] = size }
            }
            self.init(names: tartEntries.map(\.name), sizesGB: sizes, sources: sources, instances: instances)
        }
    }

    public let sections: [Section]

    /// Every entry, sections in runtime order (tart, container, docker).
    public var entries: [Entry] { sections.flatMap(\.entries) }

    /// The names of every installed image, for "did you mean" hints.
    public var presentNames: [String] { entries.filter(\.present).map(\.name) }

    public init(sections: [Section]) {
        self.sections = sections
    }

    // MARK: - Building

    /// The inventory from injected listings. `tart` is always required (its
    /// section carries the "tart is not installed" reason); the Linux
    /// runtimes are optional — nil omits the section entirely (the CLI passes
    /// one only when the runtime is installed or configured). `only` narrows
    /// the result to the named runtimes (nil = every section offered above),
    /// which is what `image list --runtime <name>` prints.
    public static func build(
        config: KinhinConfig, tart: RuntimeImages, container: RuntimeImages? = nil,
        docker: RuntimeImages? = nil, fleet: [VMRecord] = [], projectRecords: [ProjectImageRecord] = [],
        only: Set<Runtime>? = nil
    ) -> ImageInventory {
        var sections: [Section] = []
        if requested(.tart, in: only) {
            sections.append(section(.tart, config: config, images: tart, fleet: fleet, projectRecords: projectRecords))
        }
        if let container, requested(.container, in: only) {
            sections.append(section(.container, config: config, images: container))
        }
        if let docker, requested(.docker, in: only) {
            sections.append(section(.docker, config: config, images: docker))
        }
        return ImageInventory(sections: sections)
    }

    /// One runtime's section from a listing the caller already holds — the
    /// piece the checklist's image rows, the doctor's runtime sections and
    /// `image list` all reason over, so "is this image here?" has exactly one
    /// implementation. `build` composes these sections.
    public static func section(
        _ runtime: Runtime, config: KinhinConfig, images: RuntimeImages,
        fleet: [VMRecord] = [], projectRecords: [ProjectImageRecord] = []
    ) -> Section {
        switch runtime {
        case .tart:
            return tartSection(config, images, fleet: fleet, projectRecords: projectRecords)
        case .container:
            return ociSection(.container, images, wanted: config.container?.image)
        case .docker:
            return ociSection(.docker, images, wanted: config.docker?.image)
        }
    }

    private static func requested(_ runtime: Runtime, in only: Set<Runtime>?) -> Bool {
        only?.contains(runtime) ?? true
    }

    /// The production gatherer: `tart list`, the container/docker listings
    /// (only for runtimes that are installed or configured), and the two
    /// kinhin stores (fleet VMs, derived-image index). `only` restricts both
    /// the probing and the result — a filtered listing never shells out to
    /// the runtimes it was not asked about.
    public static func probe(config: KinhinConfig, only: Set<Runtime>? = nil) async throws -> ImageInventory {
        let fleet = FleetStore().all
        let records = ProjectImageStore().all
        let tart =
            requested(.tart, in: only)
            ? await listTart(config, fleet: fleet)
            : RuntimeImages()  // unused: the section is filtered out below
        return build(
            config: config,
            tart: tart,
            container: requested(.container, in: only) ? try await probeContainer(config) : nil,
            docker: requested(.docker, in: only) ? try await probeDocker(config) : nil,
            fleet: fleet, projectRecords: records, only: only)
    }

    /// Asks one runtime for its local images — the single implementation
    /// behind `image list`, the checklist's image rows and the doctor's
    /// runtime sections, so no surface ships its own copy of "list the
    /// images". Deliberately no health check: the checklist and the doctor
    /// report readiness as their own row and list only when it is green.
    /// Who is running from those images is `withInstances`, used only by
    /// the full inventory. `sizes` adds each image's disk usage (one more
    /// CLI call) for the same reason: the inventory's per-runtime totals,
    /// not the checklist's image-present row.
    public static func listing(
        runtime: Runtime, config: KinhinConfig?, fleet: [VMRecord] = [], sizes: Bool = false
    ) async -> RuntimeImages {
        switch runtime {
        case .tart:
            return await listTart(config, fleet: fleet)
        case .container:
            let container = AppleContainerRuntime()
            let names = await container.localImageNames()
            return RuntimeImages(names: names, sizesGB: sizes ? await container.localImageSizes() : [:])
        case .docker:
            let docker = DockerRuntime(image: config?.docker?.image ?? "kinhin-ci-linux")
            let names = await docker.localImageNames()
            return RuntimeImages(names: names, sizesGB: sizes ? await docker.localImageSizes() : [:])
        }
    }

    /// `images` plus the kinhin instances `list` reports. A failed listing
    /// does not read as "nothing is running": the result carries
    /// `usageUnknown`, which keeps delete and prune away from the runtime's
    /// images. Cancellation propagates.
    static func withInstances(
        _ images: RuntimeImages, runtime: Runtime, list: () async throws -> [String]
    ) async throws -> RuntimeImages {
        let users: [String]
        let usageUnknown: String?
        do {
            users = try await list().filter { $0.hasPrefix(InstanceNaming.prefix) }
            usageUnknown = nil
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            users = []
            usageUnknown = "could not list \(runtime.rawValue) instances: \(error.localizedDescription)"
        }
        return RuntimeImages(
            unavailable: images.unavailable, names: images.names, sizesGB: images.sizesGB,
            sources: images.sources, instances: users, usageUnknown: usageUnknown)
    }

    /// `tart list` as a listing: names, sources, sizes — plus the fleet's VM
    /// ids as this runtime's instances (they came from that listing too).
    private static func listTart(_ config: KinhinConfig?, fleet: [VMRecord]) async -> RuntimeImages {
        let tart: TartController
        do {
            tart = try TartController(configuredPath: config?.tartPath)
        } catch {
            // The error names the configured `tart_path:` (or PATH) and the install command.
            return RuntimeImages(unavailable: error.localizedDescription)
        }
        do {
            return RuntimeImages(tartEntries: try await tart.list(), instances: fleet.map(\.id))
        } catch {
            return RuntimeImages(unavailable: "could not list tart images: \(error.localizedDescription)")
        }
    }

    /// The apple-container section, or nil when the runtime is neither
    /// configured nor installed (nothing to say about it).
    private static func probeContainer(_ config: KinhinConfig) async throws -> RuntimeImages? {
        guard config.container != nil || Paths.findExecutable(named: "container") != nil else { return nil }
        if config.container == nil, await AppleContainerRuntime().health() != .ready { return nil }
        switch await AppleContainerRuntime().health() {
        case .ready:
            let images = await listing(runtime: .container, config: config, sizes: true)
            return try await withInstances(images, runtime: .container) {
                try await AppleContainerRuntime().existingInstanceIDs()
            }
        case .missing(_, let fix):
            return RuntimeImages(unavailable: "the container CLI is not installed — \(fix)")
        case .broken(let why):
            return RuntimeImages(unavailable: why)
        }
    }

    /// The Docker section, or nil when the runtime is neither configured nor
    /// installed. Same shape as `probeContainer`.
    private static func probeDocker(_ config: KinhinConfig) async throws -> RuntimeImages? {
        guard config.docker != nil || Paths.findExecutable(named: "docker") != nil else { return nil }
        if config.docker == nil, await DockerRuntime(image: "kinhin-ci-linux").health() != .ready { return nil }
        let docker = DockerRuntime(image: config.docker?.image ?? "kinhin-ci-linux")
        switch await docker.health() {
        case .ready:
            let images = await listing(runtime: .docker, config: config, sizes: true)
            return try await withInstances(images, runtime: .docker) { try await docker.existingInstanceIDs() }
        case .missing(_, let fix):
            return RuntimeImages(unavailable: "docker is not available — \(fix)")
        case .broken(let why):
            return RuntimeImages(unavailable: why)
        }
    }

    // MARK: - Tart

    private static func tartSection(
        _ config: KinhinConfig, _ images: RuntimeImages, fleet: [VMRecord], projectRecords: [ProjectImageRecord]
    ) -> Section {
        let named = config.images.map(\.name)
        let known = Set([config.image] + named + projectRecords.map(\.name))
        let records = Dictionary(projectRecords.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let listed = Set(images.names)
        var entries: [Entry] = []

        for name in images.names.sorted() where !isRunnerVM(name, fleet: fleet, known: known) {
            let role: Role
            if name == config.image {
                role = .base
            } else if named.contains(name) {
                role = .named
            } else if records[name] != nil {
                role = .derived
            } else {
                role = .local
            }
            // Base-image clones carry no `image` on their record; every other
            // instance names the derived image it was cloned from.
            let usedBy = fleet.filter { $0.image == name || (role == .base && $0.image == nil) }.map(\.id).sorted()
            entries.append(
                Entry(
                    name: name, runtime: .tart, role: role, present: true,
                    source: images.sources[name], sizeGB: images.sizesGB[name],
                    lastUsedAt: records[name]?.lastUsedAt, summary: records[name]?.summary, usedBy: usedBy))
        }

        // "Configured but not built" and stale index entries need to know
        // what is on disk, so they are only claimed when the listing worked.
        if images.unavailable == nil {
            let configured: [(String, Role)] = [(config.image, .base)] + named.map { ($0, Role.named) }
            for (name, role) in configured where !listed.contains(name) {
                entries.append(Entry(name: name, runtime: .tart, role: role, present: false))
            }
            for record in projectRecords where !listed.contains(record.name) {
                entries.append(
                    Entry(
                        name: record.name, runtime: .tart, role: .derived, present: false, stale: true,
                        lastUsedAt: record.lastUsedAt, summary: record.summary))
            }
        }
        return Section(runtime: .tart, unavailable: images.unavailable, entries: sorted(entries))
    }

    /// A `tart list` row that kinhin runs as an instance, not an image:
    /// a tracked runner VM, a leftover image-build scratch VM, or (when it is
    /// not a known image) anything else carrying the runner prefixes.
    private static func isRunnerVM(_ name: String, fleet: [VMRecord], known: Set<String>) -> Bool {
        if known.contains(name) { return false }
        if fleet.contains(where: { $0.id == name }) { return true }
        if name.hasPrefix(ImagePreparer.scratchPrefix) { return true }
        return InstanceNaming.isOurs(name)
    }

    // MARK: - Container / Docker

    private static func ociSection(_ runtime: Runtime, _ images: RuntimeImages, wanted: String?) -> Section {
        var entries: [Entry] = []
        let listed = Set(images.names.filter { !$0.isEmpty && !$0.contains("<none>") })
        for name in listed.sorted() {
            let matches = wanted.map { ociMatches(name: name, wanted: $0) } ?? false
            let uses = matches && wanted.map { ociUses(name: name, wanted: $0) } == true
            entries.append(
                Entry(
                    name: name, runtime: runtime, role: matches ? .base : .local, present: true,
                    sizeGB: images.sizesGB[name],
                    usedBy: uses ? images.instances.sorted() : []))
        }
        if let wanted, images.unavailable == nil, !listed.contains(where: { ociMatches(name: $0, wanted: wanted) }) {
            entries.append(Entry(name: wanted, runtime: runtime, role: .base, present: false))
        }
        return Section(
            runtime: runtime, unavailable: images.unavailable, usageUnknown: images.usageUnknown,
            entries: sorted(entries))
    }

    /// The `name:tag` form a configured image reference can match (`x` also
    /// matches `x:latest` and every tag of `x`).
    static func ociMatches(name: String, wanted: String) -> Bool {
        name == wanted || name.hasPrefix("\(wanted):")
    }

    /// The one tag runner containers actually start from: the name itself, or
    /// `:latest` when the config carries no tag.
    static func ociUses(name: String, wanted: String) -> Bool {
        if name == wanted { return true }
        return !wanted.contains(":") && name == "\(wanted):latest"
    }

    /// base, named, derived, local — then alphabetical, so the listing (and
    /// its JSON form) is stable across runs.
    private static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { lhs, rhs in
            if lhs.role != rhs.role { return roleRank(lhs.role) < roleRank(rhs.role) }
            return lhs.name < rhs.name
        }
    }

    private static func roleRank(_ role: Role) -> Int {
        switch role {
        case .base: return 0
        case .named: return 1
        case .derived: return 2
        case .local: return 3
        }
    }
}
