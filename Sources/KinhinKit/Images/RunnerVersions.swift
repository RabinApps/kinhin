import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Resolves the runner-agent versions to bake into images from the vendors'
/// release feeds instead of hardcoding: GitHub's actions-runner from
/// github.com/actions/runner/releases, Gitea's runner from
/// gitea.com/gitea/runner/releases, GitLab's from the gitlab-org/gitlab-runner
/// project's releases. Falls back to the last-known-good pinned
/// versions when the feed is unreachable (offline hosts, rate limits), and
/// degrades to pre-release tags only when nothing stable exists.
public struct RunnerVersionResolver {
    public struct Versions: Sendable, Equatable {
        public let github: String
        public let gitea: String
        public let gitlab: String

        public init(github: String, gitea: String, gitlab: String = RunnerVersionResolver.pinnedGitLab) {
            self.github = github
            self.gitea = gitea
            self.gitlab = gitlab
        }
    }

    public static let pinnedGitLab = "19.4.1"
    static let fallback = Versions(github: "2.325.0", gitea: "3.5.0", gitlab: pinnedGitLab)

    /// Release-feed endpoints. Both are string literals, so parsing them
    /// failing is a programming error rather than a runtime condition.
    static let githubFeed = feedURL("https://api.github.com/repos/actions/runner/releases/latest")
    static let giteaFeed = feedURL("https://gitea.com/api/v1/repos/gitea/runner/releases/latest")
    static let gitlabFeed = feedURL(
        "https://gitlab.com/api/v4/projects/gitlab-org%2Fgitlab-runner/releases/permalink/latest")

    private static func feedURL(_ string: String) -> URL {
        guard let url = URL(string: string) else { preconditionFailure("invalid release feed URL literal: \(string)") }
        return url
    }

    let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            self.session = URLSession(configuration: config)
        }
    }

    /// Fetch every latest stable version. Network failures yield the pinned
    /// fallback so image preparation always proceeds, and each feed failure is
    /// logged. A feed that answers with an unusable payload is also logged (and
    /// falls back); it is surfaced by the throwing ``latestGitHub()``-family
    /// members for callers that need the distinction.
    public func resolve() async -> Versions {
        async let githubTask = resolveLoggingFailures(latestGitHub, fallback: Self.fallback.github, feed: "GitHub")
        async let giteaTask = resolveLoggingFailures(latestGitea, fallback: Self.fallback.gitea, feed: "Gitea")
        async let gitlabTask = resolveLoggingFailures(latestGitLab, fallback: Self.fallback.gitlab, feed: "GitLab")
        return await Versions(github: githubTask, gitea: giteaTask, gitlab: gitlabTask)
    }

    /// One feed lookup with its fallback: a thrown error is logged, never
    /// propagated — pinned versions keep image preparation offline-safe.
    private func resolveLoggingFailures(
        _ lookup: () async throws -> String, fallback: String, feed: String
    ) async -> String {
        do {
            return try await lookup()
        } catch {
            Log.warn(
                "image", "\(feed) runner version lookup failed, using pinned \(fallback): \(error.localizedDescription)"
            )
            return fallback
        }
    }

    /// Latest stable actions-runner tag, e.g. "v2.325.0" → "2.325.0".
    /// Throws only when the feed answered with an unusable payload; network
    /// failures surface as the pinned fallback via ``resolve()``.
    func latestGitHub() async throws -> String {
        guard let data = await fetchLogged(url: Self.githubFeed) else {
            return Self.fallback.github
        }
        return try Self.stableTag(from: data, feed: "GitHub", fallback: Self.fallback.github)
    }

    /// Latest stable Gitea runner tag, e.g. "v3.5.0" → "3.5.0". Same
    /// failure behavior as ``latestGitHub()``.
    func latestGitea() async throws -> String {
        guard let data = await fetchLogged(url: Self.giteaFeed) else {
            return Self.fallback.gitea
        }
        return try Self.stableTag(from: data, feed: "Gitea", fallback: Self.fallback.gitea)
    }

    /// Latest stable GitLab runner tag, e.g. "v19.4.1" → "19.4.1". Same
    /// failure behavior as ``latestGitHub()``.
    func latestGitLab() async throws -> String {
        guard let data = await fetchLogged(url: Self.gitlabFeed) else {
            return Self.fallback.gitlab
        }
        return try Self.stableTag(from: data, feed: "GitLab", fallback: Self.fallback.gitlab, excludesDashes: true)
    }

    /// Decodes a release-feed payload to its stable tag (`v` prefix, dotted
    /// numbers; GitLab additionally excludes pre-release dashes). Throws
    /// `ImageError.malformedVersionFeed` — never returns nil — when the
    /// payload is undecodable or the tag is malformed, so "unusable answer"
    /// is distinguishable from "no data".
    static func stableTag(from data: Data, feed: String, fallback: String, excludesDashes: Bool = false)
        throws -> String
    {
        struct Payload: Decodable { let tag_name: String }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw ImageError.malformedVersionFeed(feed: feed, reason: "payload is not JSON with a tag_name string")
        }
        let tag = payload.tag_name
        guard tag.hasPrefix("v"), tag.dropFirst().contains("."), !(excludesDashes && tag.contains("-")) else {
            throw ImageError.malformedVersionFeed(feed: feed, reason: "tag '\(tag)' is not a stable v-prefixed version")
        }
        return String(tag.dropFirst())
    }

    /// Network failure of a best-effort lookup: logged and reported as nil so
    /// callers degrade to the pinned versions ("no data"), while a *malformed*
    /// answer from the feed throws from the `latest*` members instead.
    private func fetchLogged(url: URL) async -> Data? {
        do {
            return try await fetch(url: url)
        } catch {
            Log.warn("image", "runner version lookup failed for \(url.host ?? "feed"): \(error.localizedDescription)")
            return nil
        }
    }

    func fetch(url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("Kinhin/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
