import Foundation
import KinhinKit

/// `kinhin cleanup` — reclaims what kinhin leaves on the Mac: leftover runner
/// VMs, the baked base image and the shared toolchain cache. Nothing is deleted
/// without `--yes`; without it the command only reports what it would remove.
/// Enumeration and deletion live in `CleanupPlan` (KinhinKit) so the reset
/// command's "everything" scope shares them; this file is flags and output.
enum CleanupCommand {
    /// Which groups the flags select. `--all` sets every group; bare
    /// `kinhin cleanup` looks at everything too (a report only; it deletes
    /// nothing without `--yes`).
    struct Selection: Equatable {
        var targets: CleanupPlan.Targets

        init(args: [String]) {
            let all = hasFlag("--all", in: args)
            targets = CleanupPlan.Targets(
                vms: all || hasFlag("--vms", in: args),
                image: all || hasFlag("--image", in: args),
                cache: all || hasFlag("--cache", in: args))
            if targets == .init() { targets = .all }
        }

        init(targets: CleanupPlan.Targets) {
            self.targets = targets
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
        let plan = try await CleanupPlan.plan(
            targets: selection.targets, tart: tart, baseImage: config.image,
            namedImages: config.images.map(\.name), cacheRoot: Paths.toolchainCache)

        if plan.isEmpty {
            print("nothing to clean up")
            return
        }
        print(plan.describe(willDelete: confirmed))
        guard confirmed else {
            print("")
            print("nothing was deleted; re-run with --yes to remove the above (stop the fleet first: kinhin stop)")
            return
        }
        try await plan.execute(tart: tart, cacheRoot: Paths.toolchainCache)
        print("done")
    }
}
