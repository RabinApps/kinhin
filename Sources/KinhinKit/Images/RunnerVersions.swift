import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Resolves the runner-agent versions to bake into images from the vendors'
/// release feeds instead of hardcoding: GitHub's actions-runner from
/// github.com/actions/runner/releases, Gitea's runner from
/// gitea.com/gitea/runner/releases. Falls back to the last-known-good pinned
/// versions when the feed is unreachable (offline hosts, rate limits), and
/// degrades to pre-release tags only when nothing stable exists.
public struct RunnerVersionResolver {
    public struct Versions: Sendable, Equatable {
        public let github: String
        public let gitea: String
    }

    public static let fallback = Versions(github: "2.325.0", gitea: "3.5.0")

    let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            self.session = session ?? URLSession(configuration: config)
        }
    }

    /// Fetch both latest stable versions. Never throws: any failure yields
    /// the pinned fallback so image preparation always proceeds.
    public func resolve() async -> Versions {
        async let githubTask = latestGitHub()
        async let giteaTask = latestGitea()
        return await Versions(github: githubTask ?? Self.fallback.github, gitea: giteaTask ?? Self.fallback.gitea)
    }

    /// Latest stable actions-runner tag, e.g. "v2.325.0" → "2.325.0".
    func latestGitHub() async -> String? {
        guard
            let data = await fetchLogged(
                url: URL(string: "https://api.github.com/repos/actions/runner/releases/latest")!
            )
        else { return nil }
        struct Payload: Decodable { let tag_name: String }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let tag = payload.tag_name
        guard tag.hasPrefix("v"), tag.dropFirst().contains(".") else { return nil }
        return String(tag.dropFirst())
    }

    /// Latest stable Gitea runner tag, e.g. "v3.5.0" → "3.5.0".
    func latestGitea() async -> String? {
        guard
            let data = await fetchLogged(
                url: URL(string: "https://gitea.com/api/v1/repos/gitea/runner/releases/latest")!
            )
        else { return nil }
        struct Payload: Decodable { let tag_name: String }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let tag = payload.tag_name
        guard tag.hasPrefix("v"), tag.dropFirst().contains(".") else { return nil }
        return String(tag.dropFirst())
    }

    /// Version lookup is best-effort (callers fall back to pinned versions),
    /// but an offline or rate-limited feed is worth a log line.
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
