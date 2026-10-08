import Foundation
import KinhinKit

// MARK: - Token target and account resolution

extension AuthCommand {
    /// The permissions the token for `forge` needs, for the configured scope
    /// (both repo and org cases when there is no config yet).
    static func requirements(for forge: ForgeID, config: KinhinConfig?) -> TokenRequirements {
        switch forge {
        case .gitea:
            return TokenRequirements.gitea(scope: config?.gitea?.scope ?? "", instance: config?.gitea?.instance)
        case .forgejo:
            return TokenRequirements.gitea(scope: config?.forgejo?.scope ?? "", instance: config?.forgejo?.instance)
        case .github:
            return TokenRequirements.github(scope: config?.repo ?? "")
        case .gitlab:
            let account = config?.accounts.first { $0.forge == .gitlab }
            return TokenRequirements.gitlab(scope: account?.scope ?? "", instance: account?.instance)
        case .buildkite:
            return TokenRequirements.buildkite(scope: config?.accounts.first { $0.forge == .buildkite }?.scope ?? "")
        case .azuredevops:
            let account = config?.accounts.first { $0.forge == .azuredevops }
            return TokenRequirements.azureDevOps(scope: account?.scope ?? "", instance: account?.instance)
        case .bitbucket:
            return TokenRequirements.bitbucket(scope: config?.accounts.first { $0.forge == .bitbucket }?.scope ?? "")
        }
    }

    /// Resolves `--account NAME` to its forge: "github"/"gitea"/"forgejo" are
    /// the legacy accounts, anything else must be an `accounts:` entry in the
    /// config.
    static func resolveAccount(_ name: String, config: KinhinConfig?) -> AccountConfig? {
        config?.allAccounts.first { $0.name == name }
            ?? ForgeID(rawValue: name).flatMap { forge in
                AccountConfig.reservedNames.contains(name) ? AccountConfig(name: name, forge: forge, scope: "") : nil
            }
    }

    /// The forge chosen by `--github`/`--gitlab`/`--gitea`/… ; nil when none
    /// or several are given.
    static func forgeFlag(in args: [String]) -> ForgeID? {
        let chosen = ForgeID.allCases.filter { args.contains("--\($0.rawValue)") }
        return chosen.count == 1 ? chosen.first : nil
    }

    /// Every forge flag, for usage lines: `--github|--gitlab|…`.
    static var forgeFlagList: String {
        ForgeID.allCases.map { "--\($0.rawValue)" }.joined(separator: "|")
    }

    /// The token `set`, `status` and `clear` act on: a forge's primary token
    /// (`--gitea`, `--forgejo`, default GitHub) or a named account
    /// (`--account NAME`; `--gitlab` means the first GitLab account).
    struct Target {
        var forge: ForgeID
        /// Set for a named account with its own Keychain item.
        var named: AccountConfig?

        var label: String {
            let kind: String
            switch forge {
            case .github: kind = "GitHub PAT"
            case .gitea: kind = "Gitea access token"
            case .forgejo: kind = "Forgejo access token"
            case .gitlab: kind = "GitLab access token"
            case .buildkite: kind = "Buildkite API access token"
            case .azuredevops: kind = "Azure DevOps personal access token"
            case .bitbucket: kind = "Bitbucket access token"
            }
            return named.map { "\(kind) for account '\($0.name)'" } ?? kind
        }

        func load(_ environment: AuthEnvironment) throws -> String? {
            try named.map { try environment.loadAccount($0.forge, $0.name) } ?? environment.load(forge)
        }
    }

    static func resolveTarget(_ args: [String], environment: AuthEnvironment) throws -> Target {
        var target = Target(
            forge: args.contains("--forgejo") ? .forgejo : (args.contains("--gitea") ? .gitea : .github))
        var accountFlag = flag("--account", in: args)
        // Forges without a primary account (GitLab, Buildkite): the flag
        // means the forge's first account.
        let accountOnly = ForgeID.allCases.filter { !AccountConfig.reservedNames.contains($0.rawValue) }
        if accountFlag == nil, let forge = accountOnly.first(where: { args.contains("--\($0.rawValue)") }) {
            guard let first = environment.lookupConfig?.accounts.first(where: { $0.forge == forge }) else {
                try environment.fail(
                    "no \(forge.displayName) account in config — add one first: kinhin auth add NAME --\(forge.rawValue) --scope SCOPE"
                )
            }
            accountFlag = first.name
        }
        if let accountName = accountFlag {
            guard let resolved = resolveAccount(accountName, config: environment.lookupConfig) else {
                try environment.fail(
                    "no account '\(accountName)' in config — add it first: kinhin auth add \(accountName) \(forgeFlagList) --scope SCOPE"
                )
            }
            target.forge = resolved.forge
            // The conventional names keep their original Keychain items and
            // RPCs; the other forges have none, so all their accounts are
            // named ones.
            if resolved.name != resolved.forge.rawValue
                || !AccountConfig.reservedNames.contains(resolved.forge.rawValue)
            {
                target.named = resolved
            }
        }
        return target
    }
}
