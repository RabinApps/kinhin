import Foundation

// GitLabClient — the repo's `.kinhin/config.yml` (or the older `.kinhin.yml`) through the repository files API
// (raw), addressed by the URL-encoded `path_with_namespace`.
extension GitLabClient {
    public func projectFile(repository: String, ref: String?) async throws -> Data? {
        for path in ProjectFileLoader.searchPaths {
            if let data = try await projectFile(repository: repository, ref: ref, path: path) { return data }
        }
        return nil
    }

    private func projectFile(repository: String, ref: String?, path filePath: String) async throws -> Data? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard !repository.isEmpty, !repository.contains(".."),
            let project = repository.addingPercentEncoding(withAllowedCharacters: allowed)
        else {
            throw ForgeAPIError.http(forge: .gitlab, code: 0, body: "invalid project \(repository)")
        }
        let file = filePath.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        // The default branch is `HEAD`: the files API requires a ref.
        let query = [URLQueryItem(name: "ref", value: ref ?? "HEAD")]
        do {
            let (data, _) = try await send("GET", "/projects/\(project)/repository/files/\(file)/raw", query)
            return data
        } catch ForgeAPIError.notFound {
            return nil  // no file at this path and ref
        }
    }
}
