import Foundation

/// One fix from the closed allowlist the healing agent may apply. The kind
/// fixes the tier: nothing (no rule, no advisor) can make an approval or
/// manual fix run on its own.
public struct Remediation: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Delete the record and whatever is left of its instance; the
        /// autoscaler starts a replacement.
        case recycleInstance = "recycle_instance"
        /// Attach a detached account now instead of waiting out its backoff.
        case retryForgeAttach = "retry_forge_attach"
        /// Prune the host toolchain cache by its policy, plus surplus derived images.
        case pruneToolchainCache = "prune_toolchain_cache"
        /// `container system start`.
        case startContainerSystem = "start_container_system"
        /// Delete unused local images (`kinhin image prune --yes`).
        case pruneImages = "prune_images"
        /// Install a missing runtime (`kinhin setup repair <runtime>`).
        case repairRuntime = "repair_runtime"
        /// Reinstall or roll back a tart that will not launch.
        case repairTart = "repair_tart"
        /// Store a new token. Never automated: kinhin never handles tokens on its own.
        case replaceToken = "replace_token"
        /// Prepare an image (a long bake the user should start and watch).
        case prepareImage = "prepare_image"
        /// Remove a stuck instance by hand.
        case inspectInstance = "inspect_instance"
        /// Any other setup fix, by its setup action.
        case reviewSetup = "review_setup"

        public var tier: Tier {
            switch self {
            case .recycleInstance, .retryForgeAttach, .pruneToolchainCache, .startContainerSystem:
                return .automatic
            case .pruneImages, .repairRuntime, .repairTart:
                return .approval
            case .replaceToken, .prepareImage, .inspectInstance, .reviewSetup:
                return .manual
            }
        }
    }

    /// Who carries a fix out.
    public enum Tier: String, Codable, Sendable {
        /// Safe and reversible: runs without asking (unless `healing.auto: none`).
        case automatic
        /// Destructive or slow: waits for `kinhin heal approve` or the app.
        case approval
        /// Only the user can do it; kinhin says how.
        case manual
    }

    public var kind: Kind
    /// The instance, account, runtime, image or setup action it acts on.
    public var subject: String?

    public init(_ kind: Kind, subject: String? = nil) {
        self.kind = kind
        self.subject = subject
    }

    public var tier: Tier { kind.tier }

    /// One line for logs, the journal and the CLI.
    public var summary: String {
        let target = subject.map { " \($0)" } ?? ""
        switch kind {
        case .recycleInstance: return "recycle instance\(target)"
        case .retryForgeAttach: return "re-attach account\(target)"
        case .pruneToolchainCache: return "prune the toolchain cache"
        case .startContainerSystem: return "start the container system"
        case .pruneImages: return "prune unused images"
        case .repairRuntime: return "install\(target.isEmpty ? " the runtime" : target)"
        case .repairTart: return "repair tart"
        case .replaceToken: return "replace the token of\(target.isEmpty ? " the account" : target)"
        case .prepareImage: return "prepare the runner image"
        case .inspectInstance: return "remove instance\(target) by hand"
        case .reviewSetup: return "fix setup step\(target)"
        }
    }
}
