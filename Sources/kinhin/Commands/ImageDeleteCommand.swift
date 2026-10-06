import Foundation
import KinhinKit

/// `kinhin image delete <name>… [--yes]` — remove installed images by name,
/// across every runtime that holds them. Same contract as `kinhin cleanup`:
/// without `--yes` it only reports what would go (and how to re-bake each
/// configured image), and a name that is unknown, a runner VM, or in use
/// refuses the whole run *before* anything is deleted.
enum ImageDeleteCommand {
    static func run(_ args: [String]) async throws {
        var names: [String] = []
        for arg in args {
            if arg == "--yes" { continue }
            if arg.hasPrefix("-") {
                throw CLIError("unknown option '\(arg)' for image delete; the only flag is --yes", exit: .usage)
            }
            names.append(arg)
        }
        guard !names.isEmpty else {
            throw CLIError("image delete needs at least one image name — see: kinhin image list", exit: .usage)
        }
        let config = loadConfigLeniently()
        let inventory = await ImageInventory.probe(config: config)
        let plan = ImageDeletePlan.plan(names: names, inventory: inventory, fleet: FleetStore().all)
        guard plan.refusals.isEmpty else {
            for refusal in plan.refusals { printError("kinhin: \(refusal.reason)") }
            exit(exitCode(for: plan.refusals).rawValue)
        }
        guard !plan.isEmpty else {
            print("nothing to delete")
            return
        }
        for message in warnings(for: plan) { warn(message) }

        let confirmed = hasFlag("--yes", in: args)
        print(describe(plan, willDelete: confirmed))
        guard confirmed else {
            print("")
            print("nothing was deleted; re-run with --yes to remove the above (stop the fleet first: kinhin stop)")
            return
        }
        let tart = try? TartController(configuredPath: config.tartPath)
        try await plan.execute(
            tart: tart, container: AppleContainerRuntime(),
            docker: DockerRuntime(image: config.docker?.image ?? "kinhin-ci-linux"))
        let removed = Array(Set(plan.targets.filter(\.present).map(\.name))).sorted()
        print(
            removed.isEmpty
                ? "cleared \(plan.targets.count) stale derived-image record(s)"
                : "deleted \(removed.count) image(s): \(removed.joined(separator: ", "))")
    }

    // MARK: - Report

    /// The plan on stdout: one line per target, worded for the mode (`--yes`
    /// deletes, without it this is the dry run).
    static func describe(_ plan: ImageDeletePlan, willDelete: Bool) -> String {
        let verb = willDelete ? "deleting" : "would delete"
        var lines = ["\(verb) \(plan.targets.count) image(s):"]
        for target in plan.targets {
            var parts = ["\(target.name)", "(\(target.runtime.rawValue), \(target.role.rawValue))"]
            if target.stale { parts.append("(index record only — no image on disk)") }
            lines.append("  " + parts.joined(separator: "  "))
        }
        return lines.joined(separator: "\n")
    }

    /// Deleting a configured image means the fleet cannot start runners from
    /// it again until it is baked — said before the deletion, not after.
    static func warnings(for plan: ImageDeletePlan) -> [String] {
        plan.targets.compactMap { target in
            guard target.present, target.role == .base || target.role == .named else { return nil }
            return
                "'\(target.name)' is a configured image — rebuild it with `\(prepareCommand(for: target))`"
                + " before the fleet runs again"
        }
    }

    /// Refusals about the machine (something is running) end with the
    /// runtime failure code; bad names are a bad command line.
    static func exitCode(for refusals: [ImageDeletePlan.Refusal]) -> CLIExit {
        refusals.contains { $0.kind == .inUse } ? .runtime : .usage
    }

    private static func prepareCommand(for target: ImageDeletePlan.Target) -> String {
        switch target.runtime {
        case .tart:
            return target.role == .named
                ? "kinhin image prepare --image \(target.name)"
                : "kinhin image prepare"
        case .container:
            return "kinhin image prepare --container"
        case .docker:
            return "kinhin image prepare --docker"
        }
    }
}
