import Foundation
import KinhinKit

/// `kinhin image prune [--yes]` — one pass over every runtime: sweep stale
/// derived-image records (the index remembers an image tart no longer has)
/// and delete the local images nothing uses. Same contract as `kinhin image
/// delete`: without `--yes` it only reports what would go, and configured
/// images, the configured `base_image:` and anything a runner is using are
/// never candidates (in-use images are listed as kept, not refused — the
/// rest of the sweep proceeds without them).
enum ImagePruneCommand {
    static func run(_ args: [String]) async throws {
        var confirmed = false
        for arg in args {
            if arg == "--yes" { confirmed = true; continue }
            throw CLIError("unknown option '\(arg)' for image prune; the only flag is --yes", exit: .usage)
        }
        let config = loadConfigLeniently()
        let inventory = try await ImageInventory.probe(config: config)
        let plan = ImagePrunePlan.plan(inventory: inventory, config: config, fleet: FleetStore().all)
        // A runtime that could not be listed is skipped, never swept blind —
        // say so before the plan, in both modes.
        for (runtime, reason) in plan.unavailable.sorted(by: { $0.key < $1.key }) {
            warn("could not list \(runtime) images — skipped this pass: \(reason)")
        }
        guard !plan.isEmpty else {
            print("nothing to prune")
            for line in keptLines(for: plan) { print(line) }
            return
        }
        print(describe(plan, willDelete: confirmed))
        guard confirmed else {
            print("")
            print("nothing was pruned; re-run with --yes to remove the above")
            return
        }
        let tart = try ImageDeleteCommand.tartForDeletion(plan.targets, tartPath: config.tartPath)
        try await plan.execute(
            tart: tart, container: AppleContainerRuntime(),
            docker: DockerRuntime(image: config.docker?.image ?? "kinhin-ci-linux"))
        print(summary(for: plan))
    }

    // MARK: - Report

    /// The plan on stdout: one line per target, worded for the mode
    /// (`--yes` prunes, without it this is the dry run), then the images
    /// kept because runners are on them.
    static func describe(_ plan: ImagePrunePlan, willDelete: Bool) -> String {
        let verb = willDelete ? "pruning" : "would prune"
        let images = plan.targets.filter(\.present)
        let records = plan.targets.filter { !$0.present }
        var parts: [String] = []
        if !images.isEmpty { parts.append("\(images.count) unused image(s)") }
        if !records.isEmpty { parts.append("\(records.count) stale record(s)") }
        var header = "\(verb) \(parts.joined(separator: " and "))"
        if let gb = plan.reclaimGB, !images.isEmpty {
            header += gb > 0 ? " (up to ~\(gb) GB allocated)" : " (up to <1 GB allocated)"
        }
        var lines = [header + ":"]
        for target in images {
            var fields = ["  \(target.name)", "(\(target.runtime.rawValue), \(target.role.rawValue))"]
            if let size = target.sizeGB {
                fields.append(size > 0 ? "up to \(size) GB allocated" : "up to <1 GB allocated")
            }
            lines.append(fields.joined(separator: "  "))
        }
        for target in records {
            lines.append("  \(target.name)  (tart, derived)  stale record — no image on disk")
        }
        lines += keptLines(for: plan)
        return lines.joined(separator: "\n")
    }

    /// Why something that looks unused is staying: the runner count and ids.
    static func keptLines(for plan: ImagePrunePlan) -> [String] {
        plan.inUse.map { kept in
            let shown = kept.runners.prefix(3).joined(separator: ", ")
            let more = kept.runners.count > 3 ? ", …" : ""
            return "  kept \(kept.name) (\(kept.runtime.rawValue))"
                + " — in use by \(kept.runners.count) runner(s): \(shown)\(more)"
        }
    }

    /// What the confirmed pass actually did: the deleted names, the cleared
    /// record count — mirrors `image delete`'s closing line.
    static func summary(for plan: ImagePrunePlan) -> String {
        var parts: [String] = []
        let images = Set(plan.targets.filter(\.present).map(\.name)).sorted()
        if !images.isEmpty { parts.append("deleted \(images.count) image(s): \(images.joined(separator: ", "))") }
        let records = plan.targets.filter { !$0.present }.count
        if records > 0 { parts.append("cleared \(records) stale record(s)") }
        return parts.joined(separator: "; ")
    }
}
