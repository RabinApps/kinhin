import Foundation

// GiteaClient — the repo's `.kinhin/config.yml` (or the older `.kinhin.yml`) through the raw-file endpoint
// (Gitea and Forgejo share it).
extension GiteaClient {
    public func projectFile(repository: String, ref: String?) async throws -> Data? {
        for path in ProjectFileLoader.searchPaths {
            if let data = try await projectFile(repository: repository, ref: ref, path: path) { return data }
        }
        return nil
    }

    private func projectFile(repository: String, ref: String?, path file: String) async throws -> Data? {
        let segments = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 2, segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
            !repository.contains("?"), !repository.contains("#")
        else {
            throw ForgeAPIError.http(forge: .gitea, code: 0, body: "invalid repository \(repository)")
        }
        var path = "/api/v1/repos/\(repository)/raw/\(file)"
        if let ref {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            guard let encoded = ref.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            path += "?ref=\(encoded)"
        }
        do {
            let (data, _) = try await send(path: path)
            return data
        } catch ForgeAPIError.notFound {
            return nil  // no file at this path and ref
        }
    }
}
