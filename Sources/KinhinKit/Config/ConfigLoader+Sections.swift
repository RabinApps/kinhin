import Foundation

// MARK: - Section validators (base_image, Gitea family, accounts)

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

    /// Validates one Gitea-family forge section (`gitea:`, `forgejo:` — the
    /// two share the instance/scope/labels shape and validation rules).
    static func parseGiteaFamily(
        partial: PartialConfig.PartialGitea, section: String
    ) throws -> KinhinConfig.GiteaForgeConfig {
        guard let instance = partial.instance, !instance.isEmpty else {
            throw ConfigError.invalid("\(section).instance is required (e.g. https://gitea.example.com)")
        }
        do {
            _ = try GiteaCredentials.validate(instance: instance)
        } catch {
            throw ConfigError.invalid("\(section).instance must be a base URL like https://gitea.example.com (no path)")
        }
        guard let scope = partial.scope, !scope.isEmpty else {
            throw ConfigError.invalid("\(section).scope is required ('owner/name' or an org name)")
        }
        let scopeSegments = scope.split(separator: "/")
        guard (1...2).contains(scopeSegments.count),
            scopeSegments.allSatisfy({ !$0.isEmpty })
        else {
            throw ConfigError.invalid("\(section).scope must be 'owner/name' or an org name, got '\(scope)'")
        }
        if let labels = partial.labels, labels.isEmpty {
            throw ConfigError.invalid("\(section).labels must be non-empty when present")
        }
        return KinhinConfig.GiteaForgeConfig(instance: instance, scope: scope, labels: partial.labels)
    }

    /// Validates the `accounts:` list: unique tame names (not the legacy
    /// `github`/`gitea`), a known forge, a scope, and a Gitea instance URL.
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
            guard !AccountConfig.reservedNames.contains(name) else {
                throw ConfigError.invalid(
                    "\(position).name '\(name)' is reserved for the top-level repo:/gitea:/forgejo: sections — pick another name"
                )
            }
            guard seen.insert(name).inserted else {
                throw ConfigError.invalid("duplicate account name '\(name)'")
            }
            guard let rawForge = entry.forge, let forge = ForgeID(rawValue: rawForge) else {
                throw ConfigError.invalid("account '\(name)': forge must be github, gitea, forgejo or gitlab")
            }
            guard let scope = entry.scope, AccountConfig.isValidScope(scope, forge: forge) else {
                throw ConfigError.invalid(
                    forge == .gitlab
                        ? "account '\(name)': scope must be a GitLab project or group path (e.g. 'group/project')"
                        : "account '\(name)': scope must be 'owner/name' or an org name")
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
            }
        }
        return result
    }
}
