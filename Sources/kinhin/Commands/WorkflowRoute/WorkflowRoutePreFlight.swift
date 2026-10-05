import Foundation
import KinhinKit

// MARK: - Pre-flight checks for `kinhin workflow route`

enum WorkflowRoutePreFlight: Sendable, Error {
    case configMissing
    case configUnreadable(String)
    case configInvalid(String)
    case noAccountsForScope(String)
    case unavailability(WorkflowRouteAvailabilityProblem)

    var description: String {
        switch self {
        case .configMissing:
            return "no kinhin config — run: kinhin config init"
        case .configUnreadable(let path):
            return "can't read \(path): " + kString(path)
        case .configInvalid(let message):
            return "config.yaml is invalid: " + message
        case .noAccountsForScope(let scope):
            return
                "no forge account configured for scope \"\(scope)\"; add one with: kinhin auth add NAME --github|--gitlab|--gitea|--forgejo|--buildkite|--azuredevops|--bitbucket --scope SCOPE"
        case .unavailability(let problem):
            return problem.description
        }
    }
}

// MARK: - Scope resolution

/// Resolve the forge scope configured for `repository`, or nil when none.
func forgeScope(for repository: String, config: KinhinConfig) -> AccountConfig? {
    config.allAccounts.first { $0.scope == repository }
}

extension WorkflowRoutePreFlight {
    /// Build a pre-flight for `repository` against `config`. Returns nil when
    /// the config has an account for the repo (so it's routable), otherwise the failure.
    static func forRepository(_ repository: String, config: KinhinConfig) -> WorkflowRoutePreFlight? {
        guard let account = forgeScope(for: repository, config: config) else {
            return .noAccountsForScope(repository)
        }
        // Kinohin routes per label; choose label-targeting forges (GitHub/Gitea/Forgejo/Bitbucket)
        // only.  *Do not* route label-targeting to GitLab / Buildkite / Azure yet — the marker route
        // would queue forever until the user explicitly writes a tags/queue/demands rule.  That's
        // the same restriction the runtime route UI already enforces; we just surface it earlier.
        switch account.forge {
        case .github, .gitea, .forgejo, .bitbucket:
            return nil
        case .gitlab, .buildkite, .azuredevops:
            return .unavailability(WorkflowRoutePreFlight.labelTargetingNotSupported(account.forge))
        }
    }
}

// MARK: - Available routes (label-targeting + configured)

struct WorkflowRouteAvailabilityProblem: Sendable, Error {
    let labelTargetingNotSupported: ForgeID?
    let runtimeNotConfigured: RuntimeID?
    let runtimeNotPrepared: (RuntimeID, String)?

    init(
        labelTargetingNotSupported: ForgeID? = nil, runtimeNotConfigured: RuntimeID? = nil,
        runtimeNotPrepared: (RuntimeID, String)? = nil
    ) {
        self.labelTargetingNotSupported = labelTargetingNotSupported
        self.runtimeNotConfigured = runtimeNotConfigured
        self.runtimeNotPrepared = runtimeNotPrepared
    }

    var description: String {
        var parts: [String] = []
        if let unsupported = labelTargetingNotSupported {
            parts.append(
                "\(unsupported.displayName) targets jobs by tags/queues/demands, not runs-on: — write a config route: kinhin runtimes route add owner/repo@workflow tart"
            )
        }
        if let runtime = runtimeNotConfigured {
            parts.append("pool \(runtime.rawValue) isn't configured — add its section and prepare it")
        }
        if let (runtime, phase) = runtimeNotPrepared {
            parts.append(
                "\(runtime.rawValue) isn't ready for \(phase) — run: kinhin image prepare \(phase == "tart" ? "" : "--\(phase)")"
            )
        }
        return parts.isEmpty ? "no applicable routes" : parts.joined(separator: "  ")
    }
}

// MARK: - Helpers (private to the command module)

private func kString(_ x: Any) -> String {
    String(describing: x)
}

private extension ForgeID {
    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .gitea: return "Gitea"
        case .bitbucket: return "Bitbucket"
        case .forgejo: return "Forgejo"
        case .gitlab: return "GitLab"
        case .azuredevops: return "Azure DevOps"
        case .buildkite: return "Buildkite"
        }
    }
}

private extension WorkflowRoutePreFlight {
    static func labelTargetingNotSupported(_ forge: ForgeID) -> WorkflowRouteAvailabilityProblem {
        .init(labelTargetingNotSupported: forge)
    }
}
