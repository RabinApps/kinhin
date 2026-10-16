import Foundation

/// The CI systems kinhin writes pipeline files for (`kinhin mobile init --ci`, `kinhin video init --workflow --ci`): every
/// forge kinhin serves runners for, plus Buildkite.
public enum CISystem: String, CaseIterable, Sendable {
    case github
    case gitea
    case forgejo
    case gitlab
    case bitbucket
    case azure
    case buildkite

    /// How `--ci` spells the choices, for usage messages.
    public static var names: String { allCases.map(\.rawValue).joined(separator: ", ") }

    /// The system a repository uses. Buildkite and Azure Pipelines files come first, because those run on any host;
    /// then the host of the `origin` remote; then the other systems' files; GitHub when nothing says.
    public static func detect(repositoryRoot root: URL) -> CISystem {
        let fm = FileManager.default
        func has(_ path: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(path).path) }
        if has(".buildkite") { return .buildkite }
        if has("azure-pipelines.yml") || has(".azure-pipelines") { return .azure }
        // No readable .git/config just skips the remote hint; detection falls through to the files.
        let config = try? String(contentsOf: root.appendingPathComponent(".git/config"), encoding: .utf8)
        if let url = config.flatMap(originURL(gitConfig:)), let system = fromRemote(url) { return system }
        if has(".forgejo/workflows") { return .forgejo }
        if has(".gitea/workflows") { return .gitea }
        if has(".gitlab-ci.yml") { return .gitlab }
        if has("bitbucket-pipelines.yml") { return .bitbucket }
        return .github
    }

    /// The `url` of `[remote "origin"]` in a `.git/config`.
    static func originURL(gitConfig: String) -> String? {
        var inOrigin = false
        for raw in gitConfig.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line == "[remote \"origin\"]"
            } else if inOrigin, line.hasPrefix("url"), let equals = line.firstIndex(of: "=") {
                return line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// The system a remote URL's host implies (`https://`, `ssh://` and `git@host:owner/repo` forms); nil for a host
    /// that names none.
    static func fromRemote(_ url: String) -> CISystem? {
        let host: String
        if url.contains("://") {
            guard let parsed = URL(string: url)?.host else { return nil }
            host = parsed
        } else {
            // scp-like: [user@]host:path
            let beforePath = url.split(separator: ":", maxSplits: 1).first.map(String.init) ?? url
            host = beforePath.split(separator: "@").last.map(String.init) ?? beforePath
        }
        let name = host.lowercased()
        if name == "github.com" || name.hasSuffix(".ghe.com") { return .github }
        if name == "bitbucket.org" { return .bitbucket }
        if ["dev.azure.com", "ssh.dev.azure.com"].contains(name) || name.hasSuffix(".visualstudio.com") {
            return .azure
        }
        if name == "codeberg.org" || name.contains("forgejo") { return .forgejo }
        if name.contains("gitea") { return .gitea }
        if name.contains("gitlab") { return .gitlab }
        return nil
    }
}
