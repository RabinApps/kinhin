import Foundation
import Yams

// MARK: - accounts: section

extension ForgeID {
    /// Forges whose server the user hosts, so the account may name an
    /// `instance` and may opt into plain http. The switch is exhaustive on
    /// purpose: adding a forge forces a decision here instead of silently
    /// missing a hardcoded list.
    var isSelfHosted: Bool {
        switch self {
        case .gitea, .forgejo, .gitlab, .azuredevops: return true
        case .github, .buildkite, .bitbucket: return false
        }
    }

    /// What a valid `scope:` looks like on this forge, for error messages.
    var scopeHint: String {
        switch self {
        case .gitlab: return "a GitLab project or group path (e.g. 'group/project')"
        case .buildkite: return "'org-slug/cluster' (the cluster's name or id)"
        case .azuredevops: return "the agent pool's name"
        case .bitbucket: return "a workspace slug, or 'workspace/repo-slug' for one repository"
        case .github, .gitea, .forgejo: return "'owner/name' or an org name"
        }
    }
}

extension ConfigLoader {
    /// An `http://` instance sends the token in cleartext: refuse it unless
    /// the account says `allow_insecure_http: true` (loopback is exempt).
    static func requireSecureTransport(_ instance: String, allowInsecureHTTP: Bool, account: String) throws {
        guard let url = URL(string: instance), url.scheme?.lowercased() == "http",
            !ForgeHTTP.isLoopback(host: url.host ?? ""), !allowInsecureHTTP
        else { return }
        throw ConfigError.invalid(
            "account '\(account)': instance \(instance) uses plain http, which sends the access token in cleartext. "
                + "Use https, or set allow_insecure_http: true on this account if the network is trusted"
        )
    }

    /// Validates the `accounts:` list: unique tame names, a known forge, a
    /// scope, and a Gitea-family instance URL. The names "github", "gitea"
    /// and "forgejo" are the primary accounts (they map to the original
    /// Keychain items and the app's per-forge cards).
    static func parseAccounts(_ entries: [PartialConfig.PartialAccount]) throws -> [AccountConfig] {
        var seen: Set<String> = []
        var result: [AccountConfig] = []
        for (index, entry) in entries.enumerated() {
            let position = "accounts[\(index)]"
            guard let name = entry.name, !name.isEmpty else {
                throw ConfigError.invalid("\(position).name is required")
            }
            guard AccountConfig.isValidName(name) else {
                throw ConfigError.invalid(
                    "\(position).name '\(name)' must be lowercase letters, digits, '-' or '_' (max 32)")
            }
            guard seen.insert(name).inserted else {
                throw ConfigError.invalid("duplicate account name '\(name)'")
            }
            guard let rawForge = entry.forge, let forge = ForgeID(rawValue: rawForge) else {
                let known = ForgeID.allCases.map(\.rawValue).joined(separator: ", ")
                throw ConfigError.invalid("account '\(name)': forge must be one of \(known)")
            }
            guard let scope = entry.scope, AccountConfig.isValidScope(scope, forge: forge) else {
                throw ConfigError.invalid("account '\(name)': scope must be \(forge.scopeHint)")
            }
            // Hosted forges (GitHub, Buildkite, Bitbucket) are always https.
            if entry.allowInsecureHTTP != nil && !forge.isSelfHosted {
                let selfHosted = ForgeID.allCases.filter(\.isSelfHosted).map(\.rawValue).joined(separator: ", ")
                throw ConfigError.invalid(
                    "account '\(name)': allow_insecure_http applies to self-hosted forges (\(selfHosted)) only")
            }
            let allowInsecureHTTP = entry.allowInsecureHTTP ?? false
            if forge.isSelfHosted, let instance = entry.instance {
                try requireSecureTransport(instance, allowInsecureHTTP: allowInsecureHTTP, account: name)
            }
            let account = AccountEntry(
                name: name, forge: forge, scope: scope, allowInsecureHTTP: allowInsecureHTTP, raw: entry)
            switch forge {
            case .github: result.append(try parseGitHubAccount(account))
            case .gitea, .forgejo: result.append(try parseGiteaAccount(account))
            case .gitlab: result.append(try parseGitLabAccount(account))
            case .buildkite: result.append(try parseBuildkiteAccount(account))
            case .azuredevops: result.append(try parseAzureDevOpsAccount(account))
            case .bitbucket: result.append(try parseBitbucketAccount(account))
            }
        }
        return result
    }

    /// An `accounts:` entry after the checks every forge shares.
    struct AccountEntry {
        let name: String
        let forge: ForgeID
        let scope: String
        let allowInsecureHTTP: Bool
        let raw: PartialConfig.PartialAccount
    }

    // MARK: - Per-forge accounts

    private static func rejectScaleSet(_ account: AccountEntry) throws {
        if account.raw.scaleSet != nil {
            throw ConfigError.invalid("account '\(account.name)': scale_set is github-only")
        }
    }

    private static func parseGitHubAccount(_ account: AccountEntry) throws -> AccountConfig {
        let entry = account.raw
        let name = account.name
        // Labels are deliberate gitea/forgejo/GitLab labels, so they are
        // rejected for GitHub (GitHub selects runners with `runs-on:`).
        // `scale_set` stays github-only here: the scale-set message path
        // is not wired through GHES accounts in this change.
        if entry.labels != nil {
            throw ConfigError.invalid(
                "account '\(name)': labels select runners with `runs-on:`, which GitHub does not use")
        }
        // GitHub enterprise (GHES / GHEC data residency): an optional
        // instance URL. github.com has no instance, so the field stays
        // nil and the client falls back to api.github.com / github.com.
        if let instance = entry.instance, !instance.isEmpty {
            do {
                _ = try GitHubCredentials.validate(instance: instance, allowInsecureHTTP: account.allowInsecureHTTP)
            } catch {
                throw ConfigError.invalid(
                    "account '\(name)': instance must be a base URL like https://github.example.com or https://SUB.ghe.com (no /api path)"
                )
            }
        }
        let scaleSet: AccountConfig.ScaleSetConfig?
        if let raw = entry.scaleSet, !raw.isEmpty {
            let doc = try YAMLDecoder().decode(
                PartialScaleSet.self,
                from: raw.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
            scaleSet = try parseScaleSet(doc, account: name)
        } else {
            scaleSet = nil
        }
        return AccountConfig(
            name: name, forge: account.forge, scope: account.scope, instance: entry.instance,
            allowInsecureHTTP: entry.allowInsecureHTTP, scaleSet: scaleSet)
    }

    private static func parseGiteaAccount(_ account: AccountEntry) throws -> AccountConfig {
        let entry = account.raw
        let name = account.name
        try rejectScaleSet(account)
        guard let instance = entry.instance, !instance.isEmpty else {
            throw ConfigError.invalid("account '\(name)': instance is required (e.g. https://gitea.example.com)")
        }
        do {
            _ = try GiteaCredentials.validate(instance: instance, allowInsecureHTTP: account.allowInsecureHTTP)
        } catch {
            throw ConfigError.invalid(
                "account '\(name)': instance must be a base URL like https://gitea.example.com (no path)")
        }
        if let labels = entry.labels, labels.isEmpty {
            throw ConfigError.invalid("account '\(name)': labels must be non-empty when present")
        }
        return AccountConfig(
            name: name, forge: account.forge, scope: account.scope, instance: instance, labels: entry.labels,
            allowInsecureHTTP: entry.allowInsecureHTTP)
    }

    private static func parseGitLabAccount(_ account: AccountEntry) throws -> AccountConfig {
        let entry = account.raw
        let name = account.name
        try rejectScaleSet(account)
        if let instance = entry.instance {
            do {
                _ = try GitLabCredentials.validate(instance: instance, allowInsecureHTTP: account.allowInsecureHTTP)
            } catch {
                throw ConfigError.invalid(
                    "account '\(name)': instance must be a URL like https://gitlab.example.com (no /api)")
            }
        }
        if let labels = entry.labels, labels.isEmpty {
            throw ConfigError.invalid("account '\(name)': labels must be non-empty when present")
        }
        return AccountConfig(
            name: name, forge: account.forge, scope: account.scope, instance: entry.instance, labels: entry.labels,
            allowInsecureHTTP: entry.allowInsecureHTTP)
    }

    private static func parseBuildkiteAccount(_ account: AccountEntry) throws -> AccountConfig {
        let entry = account.raw
        let name = account.name
        try rejectScaleSet(account)
        if entry.instance != nil {
            throw ConfigError.invalid("account '\(name)': Buildkite is hosted only; remove instance")
        }
        if let labels = entry.labels {
            guard !labels.isEmpty, labels.allSatisfy({ BuildkiteForge.split($0) != nil }) else {
                throw ConfigError.invalid(
                    "account '\(name)': labels must be agent tags like 'queue=kinhin' (key=value)")
            }
        }
        return AccountConfig(name: name, forge: account.forge, scope: account.scope, labels: entry.labels)
    }

    private static func parseAzureDevOpsAccount(_ account: AccountEntry) throws -> AccountConfig {
        let entry = account.raw
        let name = account.name
        try rejectScaleSet(account)
        guard let instance = entry.instance, !instance.isEmpty else {
            throw ConfigError.invalid(
                "account '\(name)': instance is required (the organization URL, e.g. https://dev.azure.com/acme)")
        }
        do {
            _ = try AzureDevOpsCredentials.validate(instance: instance, allowInsecureHTTP: account.allowInsecureHTTP)
        } catch {
            throw ConfigError.invalid(
                "account '\(name)': instance must be an organization URL like https://dev.azure.com/acme")
        }
        if let labels = entry.labels {
            guard !labels.isEmpty, labels.allSatisfy(AzureDevOpsCredentials.isValidLabel) else {
                throw ConfigError.invalid(
                    "account '\(name)': labels must be agent capabilities like 'kinhin' or 'xcode=16' "
                        + "(letters, digits and _)")
            }
        }
        return AccountConfig(
            name: name, forge: account.forge, scope: account.scope, instance: instance, labels: entry.labels,
            allowInsecureHTTP: entry.allowInsecureHTTP)
    }

    private static func parseBitbucketAccount(_ account: AccountEntry) throws -> AccountConfig {
        let entry = account.raw
        let name = account.name
        try rejectScaleSet(account)
        if entry.instance != nil {
            throw ConfigError.invalid("account '\(name)': Bitbucket is hosted only; remove instance")
        }
        if let labels = entry.labels {
            guard !labels.isEmpty else {
                throw ConfigError.invalid("account '\(name)': labels must be non-empty when present")
            }
            // The runner's own `self.hosted` and platform markers are
            // added at registration; the account's labels are the
            // extra `runs-on:` selectors.
            let reserved: Set<String> = ["self.hosted", "macos", "linux.shell"]
            guard labels.allSatisfy({ !reserved.contains($0) }) else {
                throw ConfigError.invalid(
                    "account '\(name)': labels are extra runs-on selectors; 'self.hosted', 'macos' and "
                        + "'linux.shell' are added automatically")
            }
        }
        return AccountConfig(name: name, forge: account.forge, scope: account.scope, labels: entry.labels)
    }

    // MARK: - scale_set partial decoding

    /// The minimal shape the loader decodes from a `scale_set:` YAML block.
    private struct PartialScaleSet: Decodable {
        var name: String?
        var runnerGroup: String?

        enum CodingKeys: String, CodingKey {
            case name
            case runnerGroup = "runner_group"
        }
    }

    /// Validates and builds a `ScaleSetConfig` from the parsed partial.
    private static func parseScaleSet(_ partial: PartialScaleSet, account: String) throws
        -> AccountConfig.ScaleSetConfig
    {
        guard let name = partial.name, !name.isEmpty else {
            throw ConfigError.invalid("account '\(account)': scale_set.name is required")
        }
        guard AccountConfig.ScaleSetConfig.isValidName(name) else {
            throw ConfigError.invalid(
                "account '\(account)': scale_set.name '\(name)' is not a valid runs-on label"
            )
        }
        if let group = partial.runnerGroup {
            guard !group.isEmpty else {
                throw ConfigError.invalid("account '\(account)': scale_set.runner_group must not be empty")
            }
        }
        return AccountConfig.ScaleSetConfig(name: name, runnerGroup: partial.runnerGroup)
    }
}
