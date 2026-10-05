import Foundation

// GitHubClient — the repo's `.kinhin.yml`, read through the documented
// contents endpoint (raw media type), one call per (repository, sha) thanks
// to the engine's cache.
extension GitHubClient {
    public func projectFile(repository: String, ref: String?) async throws -> Data? {
        let segments = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 2, segments.allSatisfy(Self.isValidScopeSegment) else {
            throw GitHubError.http(0, "invalid repository \(repository)")
        }
        var path = "/repos/\(repository)/contents/\(ProjectFileLoader.fileName)"
        if let ref {
            // Branch names may contain `/`, `#`, `?`: encode everything that
            // is not unreserved so the ref cannot alter the path or query.
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            guard let encoded = ref.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            path += "?ref=\(encoded)"
        }
        var req = try request(method: "GET", path: path)
        req.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        do {
            let (data, _) = try await send(req)
            return data
        } catch GitHubError.notFound {
            return nil  // no .kinhin.yml at this ref
        }
    }
}
