import Foundation
import Yams

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

    /// Validates the `images:` list: unique, safe names distinct from `image:`.
    /// Names starting with `kinhin-` or `orchard-` are rejected because fleet
    /// recovery and `kinhin cleanup` treat such VMs as runners and delete them.
    static func parseImages(
        _ entries: [PartialConfig.PartialImage], primary: String, fleetLabels: [String]
    ) throws -> [KinhinConfig.ImageConfig] {
        var seen: Set<String> = [primary]
        var seenLabelSets: Set<Set<String>> = []
        let fleet = Set(fleetLabels.map { $0.lowercased() })
        var result: [KinhinConfig.ImageConfig] = []
        for (index, entry) in entries.enumerated() {
            let position = "images[\(index)]"
            guard let name = entry.name, !name.isEmpty else {
                throw ConfigError.invalid("\(position).name is required")
            }
            guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil else {
                throw ConfigError.invalid(
                    "\(position).name '\(name)' is not valid. Use letters, numbers, '.', '_' or '-', starting with a letter or number"
                )
            }
            guard !name.hasPrefix("kinhin-"), !name.hasPrefix("orchard-") else {
                throw ConfigError.invalid(
                    "\(position).name '\(name)' must not start with 'kinhin-' or 'orchard-': those names are reserved for runner VMs"
                )
            }
            guard seen.insert(name).inserted else {
                throw ConfigError.invalid(
                    "\(position).name '\(name)' is already used (image: or another images: entry)")
            }
            if let base = entry.baseImage, let problem = TartBaseImage.problem(with: base) {
                throw ConfigError.invalid("\(position).base_image \(problem)")
            }
            if let labels = entry.labels, labels.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                throw ConfigError.invalid("\(position).labels must not contain empty labels")
            }
            if let labels = entry.labels, !labels.isEmpty {
                let own = Set(labels.map { $0.lowercased() })
                guard !own.isSubset(of: fleet) else {
                    throw ConfigError.invalid(
                        "\(position).labels must include a label that is not already in the fleet labels:, or every job would match this image"
                    )
                }
                guard seenLabelSets.insert(own).inserted else {
                    throw ConfigError.invalid(
                        "\(position).labels duplicate another image's labels, so jobs could not tell them apart")
                }
            }
            result.append(.init(name: name, baseImage: entry.baseImage, labels: entry.labels))
        }
        return result
    }

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
                switch forge {
                case .gitlab:
                    throw ConfigError.invalid(
                        "account '\(name)': scope must be a GitLab project or group path (e.g. 'group/project')")
                case .buildkite:
                    throw ConfigError.invalid(
                        "account '\(name)': scope must be 'org-slug/cluster' (the cluster's name or id)")
                case .azuredevops:
                    throw ConfigError.invalid("account '\(name)': scope must be the agent pool's name")
                case .bitbucket:
                    throw ConfigError.invalid(
                        "account '\(name)': scope must be a workspace slug, or 'workspace/repo-slug' for one repository"
                    )
                case .github, .gitea, .forgejo:
                    throw ConfigError.invalid("account '\(name)': scope must be 'owner/name' or an org name")
                }
            }
            // Hosted forges (GitHub, Buildkite, Bitbucket) are always https.
            let selfHosted = [ForgeID.gitea, .forgejo, .gitlab, .azuredevops].contains(forge)
            if entry.allowInsecureHTTP != nil && !selfHosted {
                throw ConfigError.invalid(
                    "account '\(name)': allow_insecure_http applies to self-hosted forges (gitea, forgejo, gitlab, azuredevops) only"
                )
            }
            let allowInsecureHTTP = entry.allowInsecureHTTP ?? false
            if selfHosted, let instance = entry.instance {
                try requireSecureTransport(instance, allowInsecureHTTP: allowInsecureHTTP, account: name)
            }
            switch forge {
            case .github:
                if entry.instance != nil || entry.labels != nil {
                    throw ConfigError.invalid("account '\(name)': instance and labels apply to gitea accounts only")
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
                result.append(AccountConfig(name: name, forge: forge, scope: scope, scaleSet: scaleSet))
            case .gitea, .forgejo:
                if entry.scaleSet != nil {
                    throw ConfigError.invalid("account '\(name)': scale_set is github-only")
                }
                guard let instance = entry.instance, !instance.isEmpty else {
                    throw ConfigError.invalid(
                        "account '\(name)': instance is required (e.g. https://gitea.example.com)")
                }
                do {
                    _ = try GiteaCredentials.validate(instance: instance, allowInsecureHTTP: allowInsecureHTTP)
                } catch {
                    throw ConfigError.invalid(
                        "account '\(name)': instance must be a base URL like https://gitea.example.com (no path)")
                }
                if let labels = entry.labels, labels.isEmpty {
                    throw ConfigError.invalid("account '\(name)': labels must be non-empty when present")
                }
                result.append(
                    AccountConfig(
                        name: name, forge: forge, scope: scope, instance: instance, labels: entry.labels,
                        allowInsecureHTTP: entry.allowInsecureHTTP))
            case .gitlab:
                if entry.scaleSet != nil {
                    throw ConfigError.invalid("account '\(name)': scale_set is github-only")
                }
                if let instance = entry.instance {
                    do {
                        _ = try GitLabCredentials.validate(instance: instance, allowInsecureHTTP: allowInsecureHTTP)
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
                        name: name, forge: forge, scope: scope, instance: entry.instance, labels: entry.labels,
                        allowInsecureHTTP: entry.allowInsecureHTTP))
            case .buildkite:
                if entry.scaleSet != nil {
                    throw ConfigError.invalid("account '\(name)': scale_set is github-only")
                }
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
            case .azuredevops:
                if entry.scaleSet != nil {
                    throw ConfigError.invalid("account '\(name)': scale_set is github-only")
                }
                guard let instance = entry.instance, !instance.isEmpty else {
                    throw ConfigError.invalid(
                        "account '\(name)': instance is required (the organization URL, e.g. https://dev.azure.com/acme)"
                    )
                }
                do {
                    _ = try AzureDevOpsCredentials.validate(instance: instance, allowInsecureHTTP: allowInsecureHTTP)
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
                result.append(
                    AccountConfig(
                        name: name, forge: forge, scope: scope, instance: instance, labels: entry.labels,
                        allowInsecureHTTP: entry.allowInsecureHTTP))
            case .bitbucket:
                if entry.scaleSet != nil {
                    throw ConfigError.invalid("account '\(name)': scale_set is github-only")
                }
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
                result.append(AccountConfig(name: name, forge: forge, scope: scope, labels: entry.labels))
            }
        }
        return result
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
    private static func parseScaleSet(_ partial: PartialScaleSet, account: String) throws -> AccountConfig.ScaleSetConfig {
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
