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
    public static func github(scope: String) -> TokenRequirements {
        let scope = scope.trimmingCharacters(in: .whitespaces)
        let known = !scope.isEmpty && scope != ConfigLoader.templateRepo
        let isRepo = scope.contains("/")

        let repoFine = [
            "Repository access: only '\(known ? scope : "owner/name")'",
            "Repository permissions → Administration: Read and write (register and remove runners)",
            "Repository permissions → Actions: Read-only (see queued and running jobs)",
            "Repository permissions → Metadata: Read-only (added automatically)",
        ]
        let orgFine = [
            "Resource owner: the organization '\(known ? scope : "your-org")'",
            "Repository access: All repositories",
            "Organization permissions → Self-hosted runners: Read and write (register and remove runners)",
            "Repository permissions → Actions: Read-only (see queued and running jobs)",
            "Repository permissions → Metadata: Read-only (added automatically)",
        ]
        let fineURL = "https://github.com/settings/personal-access-tokens/new"
        let classicURL = "https://github.com/settings/tokens/new"

        func options(repo: Bool) -> [Option] {
            [
                Option(kind: "Fine-grained token", url: fineURL, permissions: repo ? repoFine : orgFine),
                Option(
                    kind: "Classic token", url: classicURL,
                    permissions: repo ? ["Scope: repo"] : ["Scopes: admin:org, repo"]),
            ]
        }

        if known {
            return TokenRequirements(
                title: "GitHub token permissions for \(isRepo ? "repository" : "organization") '\(scope)'",
                options: options(repo: isRepo), note: nil)
        }
        return TokenRequirements(
            title: "GitHub token permissions",
            options: options(repo: true).map { Option(kind: "\($0.kind), one repository", url: $0.url, permissions: $0.permissions) }
                + options(repo: false).map {
                    Option(kind: "\($0.kind), whole organization", url: $0.url, permissions: $0.permissions)
                },
            note: nil)
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
        if known { permissions = isRepo ? repoScopes : orgScopes } else { permissions = repoScopes + orgScopes.map { "Organization scope only — " + $0 } }
        return TokenRequirements(
            title: "Gitea token permissions" + (known ? " for \(isRepo ? "repository" : "organization") '\(scope)'" : ""),
            options: [Option(kind: "Access token", url: url, permissions: permissions)],
            note: "The token's user must own the \(isRepo || !known ? "repository" : "organization") (or be an administrator); scopes alone aren't enough.")
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
