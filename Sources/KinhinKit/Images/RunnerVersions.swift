import Foundation
import Synchronization

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Resolves the runner-agent versions to bake into images from the vendors'
/// release feeds instead of hardcoding. Each forge's `RunnerAgentSpec` names
/// its own feed (GitHub's actions-runner, Gitea's runner, GitLab's runner,
/// the Buildkite and Azure Pipelines agents); a forge with no feed keeps its
/// pinned version. Falls back to the last-known-good pinned versions when the
/// feed is unreachable (offline hosts, rate limits), and degrades to
/// pre-release tags only when nothing stable exists.
public struct RunnerVersionResolver: Sendable {
    public struct Versions: Sendable, Equatable {
        public let github: String
        public let gitea: String
        public let gitlab: String
        public let buildkite: String
        public let azure: String
        /// The Bitbucket runner *package* version (Atlassian's own scheme,
        /// unrelated to the GitHub-hosted feeds).
        public let bitbucket: String
        /// The Temurin JDK release the Bitbucket runner needs (25).
        public let bitbucketJDK: String

        public init(
            github: String, gitea: String, gitlab: String = RunnerVersionResolver.pinnedGitLab,
            buildkite: String = RunnerVersionResolver.pinnedBuildkite,
            azure: String = RunnerVersionResolver.pinnedAzure,
            bitbucket: String = RunnerVersionResolver.pinnedBitbucket,
            bitbucketJDK: String = RunnerVersionResolver.pinnedBitbucketJDK
        ) {
            self.github = github
            self.gitea = gitea
            self.gitlab = gitlab
            self.buildkite = buildkite
            self.azure = azure
            self.bitbucket = bitbucket
            self.bitbucketJDK = bitbucketJDK
        }

        /// The fallback versions with each agent's resolved answer laid over
        /// them. `resolved` is keyed by `RunnerAgentSpec.key`; an agent
        /// without an entry keeps its pinned version.
        init(resolved: [String: String]) {
            let pinned = RunnerVersionResolver.fallback
            self.init(
                github: resolved["github"] ?? pinned.github, gitea: resolved["gitea"] ?? pinned.gitea,
                gitlab: resolved["gitlab"] ?? pinned.gitlab, buildkite: resolved["buildkite"] ?? pinned.buildkite,
                azure: resolved["azure"] ?? pinned.azure, bitbucket: resolved["bitbucket"] ?? pinned.bitbucket,
                bitbucketJDK: pinned.bitbucketJDK)
        }
    }

    public static let pinnedGitLab = "19.4.1"
    public static let pinnedBuildkite = "4.0.9"
    public static let pinnedAzure = "5.279.0"
    /// The runner package comes from Atlassian's download server, which
    /// publishes no checksums and no machine-readable latest-version feed
    /// (the changelog is prose), so the version is pinned and updated
    /// deliberately.
    public static let pinnedBitbucket = "6.0.8"
    /// Temurin JDK 25 is the runner's documented requirement (v6 runners).
    public static let pinnedBitbucketJDK = "25.0.4.1+1"
    /// SHA-256 of `atlassian-bitbucket-pipelines-runner-<version>.tar.gz`
    /// per pinned version (verified locally against the vendor download).
    public static let pinnedBitbucketRunnerDigests = [
        "6.0.8": "2628a0787492fe3bd9ca7d3d26a32c11dfc92f3c28c8270381e7c4726e2edd26"
    ]
    static let fallback = Versions(
        github: "2.325.0", gitea: "3.5.0", gitlab: pinnedGitLab, buildkite: pinnedBuildkite, azure: pinnedAzure,
        bitbucket: pinnedBitbucket, bitbucketJDK: pinnedBitbucketJDK)

    let session: URLSession
    /// Recent successful lookups, so repeated prepares within the TTL cost
    /// no network. Only the default (production) resolver shares one; a
    /// resolver built with its own session (tests) never caches.
    let cache: Cache?

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
            self.cache = nil
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            self.session = URLSession(configuration: config)
            self.cache = .shared
        }
    }

    /// In-memory feed results, keyed by feed name, valid for `ttl`.
    final class Cache: Sendable {
        static let shared = Cache(ttl: 3600)
        private let ttl: TimeInterval
        private let entries = Mutex<[String: (value: String, at: Date)]>([:])

        init(ttl: TimeInterval) { self.ttl = ttl }

        func value(for feed: String, now: Date = Date()) -> String? {
            entries.withLock { entries in
                guard let entry = entries[feed], now.timeIntervalSince(entry.at) < ttl else { return nil }
                return entry.value
            }
        }

        func store(_ value: String, for feed: String, now: Date = Date()) {
            entries.withLock { $0[feed] = (value, now) }
        }
    }

    /// Fetch every latest stable version. Network failures yield the pinned
    /// fallback so image preparation always proceeds, and each feed failure is
    /// logged. A feed that answers with an unusable payload is also logged (and
    /// falls back); it is surfaced by the throwing ``latestGitHub()``-family
    /// members for callers that need the distinction.
    ///
    /// `forges` limits the lookups to the platforms an image will actually
    /// bake (a feed nobody asked about costs a request for nothing and keeps
    /// its pinned version); nil looks every feed up.
    public func resolve(including forges: Set<ForgeID>? = nil) async -> Versions {
        let lookups = RunnerAgentSpec.all.compactMap { agent -> (RunnerAgentSpec, RunnerAgentSpec.ReleaseFeed)? in
            agent.feed.map { (agent, $0) }
        }
        let resolved = await withTaskGroup(of: (String, String).self) { group in
            for (agent, feed) in lookups {
                let enabled = forges.map { set in agent.forges.contains { set.contains($0) } } ?? true
                group.addTask {
                    (
                        agent.key,
                        await resolveLoggingFailures(
                            { try await latest(agent) }, fallback: agent.version(Self.fallback), feed: feed.name,
                            enabled: enabled)
                    )
                }
            }
            var versions: [String: String] = [:]
            for await (key, version) in group { versions[key] = version }
            return versions
        }
        return Versions(resolved: resolved)
    }

    /// One feed lookup with its fallback: a thrown error is logged, never
    /// propagated — pinned versions keep image preparation offline-safe. A
    /// disabled feed answers its pinned version without a request, and a
    /// real (non-pinned) answer is remembered for an hour.
    private func resolveLoggingFailures(
        _ lookup: () async throws -> String, fallback: String, feed: String, enabled: Bool = true
    ) async -> String {
        guard enabled else { return fallback }
        if let cached = cache?.value(for: feed) { return cached }
        do {
            let latest = try await lookup()
            // The pinned value is also what an unreachable feed yields: do not pin it for an hour.
            if latest != fallback { cache?.store(latest, for: feed) }
            return latest
        } catch {
            Log.warn(
                "image", "\(feed) runner version lookup failed, using pinned \(fallback): \(error.localizedDescription)"
            )
            return fallback
        }
    }

    /// Latest stable tag of `feed` with its leading `v` dropped, e.g.
    /// "v2.325.0" → "2.325.0". Throws only when the feed answered with an
    /// unusable payload; network failures surface as the pinned fallback.
    func latest(_ feed: RunnerAgentSpec.ReleaseFeed, fallback: String) async throws -> String {
        guard let data = await fetchLogged(url: feed.url) else { return fallback }
        return try Self.stableTag(from: data, feed: feed.name, fallback: fallback, excludesDashes: feed.excludesDashes)
    }

    func latestGitHub() async throws -> String { try await latest(RunnerAgentSpec.github) }
    func latestGitea() async throws -> String { try await latest(RunnerAgentSpec.gitea) }
    func latestGitLab() async throws -> String { try await latest(RunnerAgentSpec.gitlab) }
    func latestBuildkite() async throws -> String { try await latest(RunnerAgentSpec.buildkite) }
    func latestAzure() async throws -> String { try await latest(RunnerAgentSpec.azure) }

    /// The latest stable version of `agent`'s own feed (the pinned version
    /// when the agent has no feed).
    func latest(_ agent: RunnerAgentSpec) async throws -> String {
        guard let feed = agent.feed else { return agent.version(Self.fallback) }
        return try await latest(feed, fallback: agent.version(Self.fallback))
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
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw ImageError.malformedVersionFeed(
                feed: feed, reason: "payload is not JSON with a tag_name string (\(error.localizedDescription))")
        }
        // `\z` (not `$`): ICU's `$` also matches before a trailing newline, which would
        // let "v1.2.3\n" through into a script.
        let tag = payload.tag_name
        // The tag is spliced into bake scripts and download URLs, so only a
        // plain dotted version (optionally `-pre.release`) is accepted.
        let wellFormed = tag.range(of: #"^v[0-9]+(\.[0-9]+)+(-[A-Za-z0-9.]+)?\z"#, options: .regularExpression) != nil
        guard wellFormed, !(excludesDashes && tag.contains("-")) else {
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
