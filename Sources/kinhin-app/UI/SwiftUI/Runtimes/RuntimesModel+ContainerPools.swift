import Foundation
import KinhinKit

// Named Apple container pools (`container.pools:`) on Advanced → Routing: one card per pool with what it resolves
// to and whether its image is built, and the Add / Edit sheet (`ContainerPoolSheet`) and Remove that write the
// pools through `ContainerPoolsConfigEditor`.

extension RuntimesModel {
    // MARK: - Display

    /// One named pool's card: what the pool resolves to after the `container:` defaults are filled in.
    struct ContainerPoolRow: Identifiable, Equatable {
        let id: String
        /// "labels: …" (the pool's own labels and its `kinhin-container-<name>` marker), then shape and floors,
        /// then the image; one fact group per line.
        let detail: String
        /// Whether the pool's image is built; nil when the images could not be listed.
        let built: Bool?
        /// The pool that takes container jobs no pool's labels claim.
        let isDefault: Bool
    }

    /// The Container pools section shows only when Apple container is configured.
    var showsContainerPools: Bool { parsedConfig?.container != nil }

    /// One row per named pool, sorted by name; empty for a `container:` section without `pools:`.
    var containerPoolRows: [ContainerPoolRow] {
        guard let container = parsedConfig?.container else { return [] }
        let defaultName = container.pools.isEmpty ? nil : container.defaultPool.name
        return container.pools.map { pool in
            Self.containerPoolRow(
                pool, built: builtContainerImages?[pool.image], isDefault: pool.name == defaultName)
        }
    }

    static func containerPoolRow(
        _ pool: KinhinConfig.ContainerConfig.Pool, built: Bool?, isDefault: Bool
    ) -> ContainerPoolRow {
        let labels = (pool.labels ?? []) + [pool.marker].compactMap { $0 }
        let cpus = pool.cpus
        let memoryGB = pool.memoryGB
        let minIdle = pool.minIdle
        var shape = [
            String(
                localized: "\(cpus) vCPU · \(memoryGB) GB", bundle: .l10n,
                comment: "Container pool card: each runner's CPUs, then its memory in GB")
        ]
        if let poolMax = pool.max {
            shape.append(
                String(
                    localized: "at most \(poolMax) at once", bundle: .l10n,
                    comment: "Container pool card: the pool's max: (runners at once)"))
        }
        shape.append(
            String(
                localized: "min idle \(minIdle)", bundle: .l10n,
                comment: "Container pool card: idle runners the pool keeps (min_idle)"))
        shape.append(
            pool.docker
                ? String(localized: "Docker on", bundle: .l10n, comment: "Container pool card: docker: true")
                : String(localized: "Docker off", bundle: .l10n, comment: "Container pool card: docker: false"))
        if isDefault {
            shape.append(
                String(
                    localized: "takes unmatched jobs", bundle: .l10n,
                    comment: "Container pool card: this is the default pool, for jobs no pool's labels claim"))
        }
        var lines = [
            String(
                localized: "labels: \(labels.joined(separator: ", "))", bundle: .l10n,
                comment: "Routing tab pool detail; %@ lists runner labels"),
            shape.joined(separator: " · "),
            String(
                localized: "image: \(pool.image)", bundle: .l10n,
                comment: "Container pool card: the pool's image; %@ is an image name"),
        ]
        if built == false {
            lines.append(
                String(
                    localized:
                        "Not built yet, so its jobs wait. Build it: kinhin image prepare --container --pool \(pool.name)",
                    bundle: .l10n,
                    comment: "Container pool card; %@ is the pool name, inside a command that stays verbatim"))
        }
        return ContainerPoolRow(
            id: pool.name, detail: lines.joined(separator: "\n"), built: built, isDefault: isDefault)
    }

    /// The card's chip: built (green) or not built (orange); nothing while unknown.
    static func builtChip(_ built: Bool?) -> (text: String, style: StatusStyle)? {
        switch built {
        case true?: return (String(localized: "● built", bundle: .l10n, comment: "Container pool chip"), .ok)
        case false?: return (String(localized: "● not built", bundle: .l10n, comment: "Container pool chip"), .warn)
        case nil: return nil
        }
    }

    /// Lists the local images once per reload, when `container` (that reload's section) has named pools to mark. A
    /// failed listing marks nothing. The answer is applied only while `generation` is still the newest listing.
    func refreshContainerPoolImages(container: KinhinConfig.ContainerConfig?, generation: Int) async {
        var built: [String: Bool]?
        if let container, !container.pools.isEmpty {
            do {
                let listed = try await listContainerImages()
                let missing = Set(container.poolsMissingImage(listed: listed).map(\.image))
                built = Dictionary(
                    container.pools.map { ($0.image, !missing.contains($0.image)) },
                    uniquingKeysWith: { first, _ in first })
            } catch {
                Log.warn("runtimes-pane", "container image list failed: \(error.localizedDescription)")
            }
        }
        guard generation == containerPoolImageGeneration else { return }  // a newer reload listed since
        builtContainerImages = built
    }

    // MARK: - Sheet

    /// The open pool sheet's inputs.
    struct ContainerPoolOffer: Identifiable {
        /// The pool being edited, as written (only the keys it sets); nil adds a new pool.
        let original: ContainerPoolsConfigEditor.Pool?
        /// The `container:` section's own keys: what a blank field inherits.
        let defaults: ContainerPoolsConfigEditor.Container
        var id: String { original.map { "edit-\($0.name)" } ?? "add" }
        /// No named pool exists yet: saving this one turns the section into named pools.
        var isFirstPool: Bool { defaults.pools.isEmpty }
    }

    func addContainerPoolClicked() {
        openContainerPoolSheet(editing: nil)
    }

    func editContainerPoolClicked(name: String) {
        openContainerPoolSheet(editing: name)
    }

    private func openContainerPoolSheet(editing name: String?) {
        do {
            guard let container = try ConfigStore.snapshot(at: configURL)?.container else {
                throw ConfigEditError.unsupported(
                    String(
                        localized: "Apple container isn't enabled in config.yaml.", bundle: .l10n,
                        comment: "Routing tab: error when a container pool is edited without a container: section"))
            }
            var original: ContainerPoolsConfigEditor.Pool?
            if let name {
                guard let pool = container.pools.first(where: { $0.name == name }) else {
                    reload()  // the file changed under the card
                    return
                }
                original = pool
            }
            sheetProblem = ""
            containerPoolOffer = ContainerPoolOffer(original: original, defaults: container)
        } catch {
            presentError(error)
        }
    }

    /// Save pressed: check the fields, write through the editor (the loader gates the result), close the sheet.
    /// A problem stays inside the sheet with the values intact.
    func confirmContainerPool(_ draft: ContainerPoolDraft) {
        guard let offer = containerPoolOffer else { return }
        if let problem = draft.problem {
            sheetProblem = problem
            return
        }
        do {
            try ContainerPoolsConfigEditor.save(
                draft.pool(keeping: offer.original), replacing: offer.original?.name, at: configURL)
            containerPoolOffer = nil
            sheetProblem = ""
            reload()
            onChanged?()
        } catch {
            sheetProblem = error.localizedDescription
        }
    }

    func cancelContainerPool() {
        containerPoolOffer = nil
        sheetProblem = ""
    }

    /// Remove pressed on a card: confirm, then drop the pool from the config.
    func removeContainerPool(name: String) {
        guard
            confirmRemoval(
                String(
                    localized: "Remove container pool “\(name)”?", bundle: .l10n,
                    comment: "Confirmation title; %@ is a container pool name"),
                String(
                    localized:
                        "kinhin stops starting runners for this pool, and jobs that ask for its labels wait. Its image stays on disk.",
                    bundle: .l10n, comment: "Confirmation body for removing a container pool"),
                String(localized: "Remove", bundle: .l10n, comment: "Confirm button that removes a container pool"))
        else { return }
        do {
            try ContainerPoolsConfigEditor.remove(named: name, at: configURL)
            reload()
            onChanged?()
        } catch {
            presentError(error)
        }
    }
}
