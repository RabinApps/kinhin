import Foundation

// GitLabClient — the repo's `.kinhin.yml` through the repository files API
// (raw), addressed by the URL-encoded `path_with_namespace`.
extension GitLabClient {
    public func projectFile(repository: String, ref: String?) async throws -> Data? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard !repository.isEmpty, !repository.contains(".."),
            let project = repository.addingPercentEncoding(withAllowedCharacters: allowed)
        else {
            throw GitLabError.http(0, "invalid project \(repository)")
        }
        let file = ProjectFileLoader.fileName.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        // The default branch is `HEAD`: the files API requires a ref.
        let query = [URLQueryItem(name: "ref", value: ref ?? "HEAD")]
        do {
            let (data, _) = try await send("GET", "/projects/\(project)/repository/files/\(file)/raw", query)
            return data
        } catch GitLabError.notFound {
            return nil  // no .kinhin.yml at this ref
        }
    }
}
