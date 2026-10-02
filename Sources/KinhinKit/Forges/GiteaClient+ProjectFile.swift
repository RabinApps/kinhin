import Foundation

// GiteaClient — the repo's `.kinhin.yml` through the raw-file endpoint
// (Gitea and Forgejo share it).
extension GiteaClient {
    public func projectFile(repository: String, ref: String?) async throws -> Data? {
        let segments = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 2, segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
            !repository.contains("?"), !repository.contains("#")
        else {
            throw GiteaError.http(0, "invalid repository \(repository)")
        }
        var path = "/api/v1/repos/\(repository)/raw/\(ProjectFileLoader.fileName)"
        if let ref {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            guard let encoded = ref.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            path += "?ref=\(encoded)"
        }
        do {
            let (data, _) = try await send(path: path)
            return data
        } catch GiteaError.notFound {
            return nil  // no .kinhin.yml at this ref
        }
    }
}
