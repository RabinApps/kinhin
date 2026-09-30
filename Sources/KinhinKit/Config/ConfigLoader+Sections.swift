import Foundation

// MARK: - Section validators (base_image, accounts)

extension ConfigLoader {
    /// `base_image:` is optional; when present it must be usable as a bare
    /// image reference (see `LinuxBaseImage.problem(with:)`).
    static func validatedBaseImage(_ value: String?, key: String) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let problem = LinuxBaseImage.problem(with: trimmed) {
            throw ConfigError.invalid("\(key) \(problem) (an image like ubuntu:24.04 or debian:12)")
        }
        return trimmed
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
                switch forge {
                case .gitlab:
                    throw ConfigError.invalid(
                        "account '\(name)': scope must be a GitLab project or group path (e.g. 'group/project')")
                case .buildkite:
                    throw ConfigError.invalid(
                        "account '\(name)': scope must be 'org-slug/cluster' (the cluster's name or id)")
                case .github, .gitea, .forgejo:
                    throw ConfigError.invalid("account '\(name)': scope must be 'owner/name' or an org name")
                }
            }
            switch forge {
            case .github:
                if entry.instance != nil || entry.labels != nil {
                    throw ConfigError.invalid("account '\(name)': instance and labels apply to gitea accounts only")
                }
                result.append(AccountConfig(name: name, forge: forge, scope: scope))
            case .gitea, .forgejo:
                guard let instance = entry.instance, !instance.isEmpty else {
                    throw ConfigError.invalid(
                        "account '\(name)': instance is required (e.g. https://gitea.example.com)")
                }
                do {
                    _ = try GiteaCredentials.validate(instance: instance)
                } catch {
                    throw ConfigError.invalid(
                        "account '\(name)': instance must be a base URL like https://gitea.example.com (no path)")
                }
                if let labels = entry.labels, labels.isEmpty {
                    throw ConfigError.invalid("account '\(name)': labels must be non-empty when present")
                }
                result.append(
                    AccountConfig(name: name, forge: forge, scope: scope, instance: instance, labels: entry.labels))
            case .gitlab:
                if let instance = entry.instance {
                    do {
                        _ = try GitLabCredentials.validate(instance: instance)
                    } catch {
                        throw ConfigError.invalid(
                            "account '\(name)': instance must be a URL like https://gitlab.example.com (no /api)")
                    }
                }
                if let labels = entry.labels, labels.isEmpty {
                    throw ConfigError.invalid("account '\(name)': labels must be non-empty when present")
                }
                result.append(
                    AccountConfig(
                        name: name, forge: forge, scope: scope, instance: entry.instance, labels: entry.labels))
            case .buildkite:
                if entry.instance != nil {
                    throw ConfigError.invalid("account '\(name)': Buildkite is hosted only; remove instance")
                }
                if let labels = entry.labels {
                    guard !labels.isEmpty, labels.allSatisfy({ BuildkiteForge.split($0) != nil }) else {
                        throw ConfigError.invalid(
                            "account '\(name)': labels must be agent tags like 'queue=kinhin' (key=value)")
                    }
                }
                result.append(AccountConfig(name: name, forge: forge, scope: scope, labels: entry.labels))
            }
        }
        return result
    }
}
