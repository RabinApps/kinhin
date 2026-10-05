import Foundation

/// The exact permissions an access token needs for kinhin to serve a scope:
/// one source of truth for `kinhin auth`, `kinhin doctor`, the permission
/// probe's errors, and the app's Connect form.
///
/// What kinhin does with the token decides the list: mint runner
/// registration tokens, list and delete runners, and read queued/running
/// workflow runs and jobs (and, in the app, list the repositories to pick).
public struct TokenRequirements: Equatable, Sendable {
    /// One way to create a token (e.g. a fine-grained or classic GitHub PAT).
    public struct Option: Equatable, Sendable {
        public let kind: String
        /// Where to create it.
        public let url: String
        public let permissions: [String]
    }

    public let title: String
    public let options: [Option]
    /// Anything the permission list can't express (e.g. token owner rights).
    public let note: String?

    /// GitHub. `scope` is "owner/name" (one repository), an org name (every
    /// repo in it), or empty/unknown — then both cases are listed.
    /// `instance` (nil = github.com; a GHES host or GHEC data-residency host)
    /// controls the token-creation links and the settings base shown in the
    /// permission list.
    public static func github(scope: String, instance: String? = nil) -> TokenRequirements {
        let scope = scope.trimmingCharacters(in: .whitespaces)
        let known = !scope.isEmpty && scope != ConfigLoader.templateRepo
        let isRepo = scope.contains("/")
        let webBase: String
        if let instance, let url = URL(string: instance), let host = url.host {
            let scheme = url.scheme?.lowercased() == "http" ? "http" : "https"
            webBase = "\(scheme)://\(host)/"
        } else {
            webBase = "https://github.com/"
        }

        let repoFine = [
            "Repository access: only '\(known ? scope : "owner/name")'",
            "Repository permissions → Administration: Read and write (register and remove runners)",
            "Repository permissions → Actions: Read-only (see queued and running jobs)",
            "Repository permissions → Metadata: Read-only (added automatically)",
        ]
        let orgFine = [
            "Resource owner: the organization '\(known ? scope : "your-org")'",
            "Repository access: All repositories",
            "Organization permissions → Self-hosted runners: Read and write (register and remove runners; the only fine-grained permission org endpoints accept)",
            "Repository permissions → Actions: Read-only (see queued and running jobs — the only fine-grained runs access; GitHub has no organization-level runs permission for tokens)",
            "Repository permissions → Metadata: Read-only (added automatically)",
        ]
        let settingsBase: String
        if webBase.hasSuffix(".ghe.com") {
            settingsBase = webBase
        } else {
            settingsBase = "https://github.com"
        }
        let fineURL = "\(settingsBase)/settings/personal-access-tokens/new"
        let classicURL = "\(settingsBase)/settings/tokens/new"
        // GitHub documents no org-level runs endpoint, so org scopes read each
        // repository's runs separately; org scopes should know about it.
        let orgRunsLimitation =
            "Fine-grained and classic tokens cannot read organization-wide runs at once (GitHub documents no org-level runs endpoint) — kinhin reads each repository's runs separately."

        func options(repo: Bool) -> [Option] {
            [
                Option(kind: "Fine-grained token", url: fineURL, permissions: repo ? repoFine : orgFine),
                Option(
                    kind: "Classic token", url: classicURL,
                    permissions: repo
                        ? ["Scope: repo"]
                        : [
                            "Scopes: admin:org, repo — repo covers runners and jobs for every repository; "
                                + "admin:org manages runners"
                        ],
                ),
            ]
        }

        if known {
            return TokenRequirements(
                title: "GitHub token permissions for \(isRepo ? "repository" : "organization") '\(scope)'",
                options: options(repo: isRepo), note: isRepo ? nil : orgRunsLimitation)
        }
        return TokenRequirements(
            title: "GitHub token permissions",
            options: options(repo: true).map {
                Option(kind: "\($0.kind), one repository", url: $0.url, permissions: $0.permissions)
            }
                + options(repo: false).map {
                    Option(kind: "\($0.kind), whole organization", url: $0.url, permissions: $0.permissions)
                },
            note: orgRunsLimitation)
    }

    /// Gitea. `instance` (e.g. "https://gitea.example.com") only sharpens the
    /// link to the token page.
    public static func gitea(scope: String, instance: String? = nil) -> TokenRequirements {
        let scope = scope.trimmingCharacters(in: .whitespaces)
        let known = !scope.isEmpty
        let isRepo = scope.contains("/")
        let base = (instance ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let url = base.isEmpty ? "<your-gitea>/user/settings/applications" : "\(base)/user/settings/applications"

        let repoScopes = ["Scope: write:repository (register and remove runners, read queued jobs, list repositories)"]
        let orgScopes = [
            "Scope: write:organization (register and remove the organization's runners)",
            "Scope: read:repository (list repositories, read queued jobs)",
        ]
        let permissions: [String]
        if known {
            permissions = isRepo ? repoScopes : orgScopes
        } else {
            permissions = repoScopes + orgScopes.map { "Organization scope only — " + $0 }
        }
        return TokenRequirements(
            title: "Gitea token permissions"
                + (known ? " for \(isRepo ? "repository" : "organization") '\(scope)'" : ""),
            options: [Option(kind: "Access token", url: url, permissions: permissions)],
            note:
                "The token's user must own the \(isRepo || !known ? "repository" : "organization") (or be an administrator); scopes alone aren't enough."
        )
    }

    /// GitLab. The scope's kind (project or group) can't be told from its
    /// path, so both roles are listed. `instance` defaults to gitlab.com.
    public static func gitlab(scope: String, instance: String? = nil) -> TokenRequirements {
        let scope = scope.trimmingCharacters(in: .whitespaces)
        var base = (instance ?? GitLabCredentials.defaultInstance).trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        let scopes = "Scopes: create_runner, manage_runner, read_api (or api)"
        return TokenRequirements(
            title: "GitLab token permissions" + (scope.isEmpty ? "" : " for '\(scope)'"),
            options: [
                Option(
                    kind: "Personal access token", url: "\(base)/-/user_settings/personal_access_tokens",
                    permissions: [scopes]),
                Option(
                    kind: "Project or group access token",
                    url: "\(base)/\(scope.isEmpty ? "<group-or-project>" : scope)/-/settings/access_tokens",
                    permissions: [scopes, "Role: Maintainer (project) or Owner (group)"]),
            ],
            note: "Creating runners needs Maintainer on a project or Owner on a group, and GitLab 16.0 or later.")
    }

    /// Buildkite: an API access token (hosted only) for the organization in
    /// `scope` (`org/cluster`).
    public static func buildkite(scope: String) -> TokenRequirements {
        let organization = scope.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        return TokenRequirements(
            title: "Buildkite token permissions" + (organization.isEmpty ? "" : " for '\(organization)'"),
            options: [
                Option(
                    kind: "API access token", url: "https://buildkite.com/user/api-access-tokens",
                    permissions: [
                        "Organization access: \(organization.isEmpty ? "the organization to serve" : organization)",
                        "REST API scopes: " + BuildkiteCredentials.requiredScopes.joined(separator: ", "),
                    ])
            ],
            note:
                "kinhin creates a cluster agent token (\"kinhin: <account>\") for its agents and replaces it on each start."
        )
    }

    /// Azure DevOps: a PAT for the organization at `instance` that can manage
    /// the agent pool in `scope`. It is also what agents register with, so
    /// it reaches every instance.
    public static func azureDevOps(scope: String, instance: String? = nil) -> TokenRequirements {
        let pool = scope.trimmingCharacters(in: .whitespaces)
        var base = (instance ?? "").trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        return TokenRequirements(
            title: "Azure DevOps token permissions" + (pool.isEmpty ? "" : " for agent pool '\(pool)'"),
            options: [
                Option(
                    kind: "Personal access token",
                    url: base.isEmpty
                        ? "https://dev.azure.com/<org>/_usersSettings/tokens" : "\(base)/_usersSettings/tokens",
                    permissions: [
                        "Scope: Agent Pools (Read & manage) — nothing else",
                        "Role: Administrator on the agent pool",
                    ])
            ],
            note:
                "Agents register with this token, so it is copied into every runner instance: use a dedicated token with only this scope."
        )
    }

    /// Bitbucket Cloud: a workspace access token (workspace scope) or a
    /// repository access token (`workspace/repo` scope). App passwords lack
    /// the runner scopes.
    public static func bitbucket(scope: String) -> TokenRequirements {
        let scope = scope.trimmingCharacters(in: .whitespaces)
        let isRepo = scope.contains("/")
        let target = scope.isEmpty ? "the workspace to serve" : scope
        return TokenRequirements(
            title: "Bitbucket token permissions" + (scope.isEmpty ? "" : " for '\(scope)'"),
            options: [
                Option(
                    kind: isRepo ? "Repository access token" : "Workspace access token",
                    url: isRepo
                        ? "https://bitbucket.org/\(target)/settings/access_tokens"
                        : "https://bitbucket.org/\(target.isEmpty ? "<workspace>" : target)/settings/access-tokens",
                    permissions: [
                        isRepo
                            ? "Scopes: runner:write, runner:read, pipeline:read (repository tokens)"
                            : "Scopes: runner (or runner:write + runner:read), pipeline (or pipeline:read)"
                    ])
            ],
            note:
                "App passwords do not cover runners — use a workspace or repository access token. kinhin creates one runner per instance and captures its OAuth secret at creation."
        )
    }

    /// Multi-line text for the CLI and log lines.
    public var plainText: String {
        var lines = ["\(title):"]
        for option in options {
            lines.append("  \(option.kind)  (\(option.url))")
            lines.append(contentsOf: option.permissions.map { "    • \($0)" })
        }
        if let note { lines.append("  \(note)") }
        return lines.joined(separator: "\n")
    }

    /// Compact one-liner for error messages, preferring the first option.
    public var summary: String {
        guard let first = options.first else { return "" }
        return "\(first.kind): " + first.permissions.joined(separator: "; ")
    }
}
