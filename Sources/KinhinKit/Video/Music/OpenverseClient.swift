import Foundation

/// Searches Openverse (openverse.org), one index of openly licensed audio from Freesound, Wikimedia Commons and others.
/// No account or key is needed; anonymous use is limited to 20 requests a minute and 200 a day.
public struct OpenverseClient: Sendable {
    public static let endpoint = "https://api.openverse.org/v1/audio/"

    let session: URLSession

    public init(session: URLSession = OpenverseClient.makeSession()) {
        self.session = session
    }

    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }

    static var userAgent: String { "kinhin/\(kinhinVersion.current) (+https://github.com/RabinApps/kinhin)" }

    /// Audio matching `query` under one of `licenses` (`cc0`, `pdm`, `by`). Mature results are never asked for.
    /// Anonymous requests may ask for at most 20 results a page, so more come from later `page`s.
    public static let anonymousPageSize = 20

    public func search(query: String, licenses: [String], page: Int = 1) async throws -> [MusicTrack] {
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "license", value: licenses.joined(separator: ",")),
            URLQueryItem(name: "page_size", value: String(Self.anonymousPageSize)),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "mature", value: "false"),
        ]
        let data = try await fetch(components.url!, pastTheEndIsEmpty: true)
        let page: SearchPage
        do { page = try JSONDecoder().decode(SearchPage.self, from: data) } catch {
            throw MusicError.network("unexpected answer")
        }
        return page.results.compactMap(\.track)
    }

    /// One result by its Openverse id.
    public func detail(id: String) async throws -> MusicTrack {
        guard let url = URL(string: Self.endpoint + id + "/"), UUID(uuidString: id) != nil else {
            throw MusicError.notFound(id)
        }
        let data = try await fetch(url, pastTheEndIsEmpty: false)
        guard let track = (try? JSONDecoder().decode(Result.self, from: data))?.track else {
            throw MusicError.notFound(id)
        }
        return track
    }

    private func fetch(_ url: URL, pastTheEndIsEmpty: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            if error is CancellationError { throw error }
            throw MusicError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw MusicError.network("no answer") }
        switch http.statusCode {
        case 200: return data
        case 404 where pastTheEndIsEmpty: return Data(#"{"results":[]}"#.utf8)  // past the last page
        case 404: throw MusicError.notFound(url.lastPathComponent)
        case 429:
            throw MusicError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) })
        default:
            let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.detail
            throw MusicError.network(detail ?? "HTTP \(http.statusCode)")
        }
    }

    // MARK: wire format

    struct ErrorBody: Decodable {
        var detail: String?
    }

    struct SearchPage: Decodable {
        var results: [Result]
    }

    struct Result: Decodable {
        var id: String
        var title: String?
        var creator: String?
        var license: String?
        var license_version: String?
        var license_url: String?
        var source: String?
        var provider: String?
        var foreign_landing_url: String?
        var url: String?
        var filetype: String?
        var duration: Int?
        var filesize: Int?
        var attribution: String?
        var mature: Bool?

        /// Nil for a result with no file to download, or one marked mature.
        var track: MusicTrack? {
            guard let url, !url.isEmpty, mature != true, let license, !license.isEmpty else { return nil }
            return MusicTrack(
                origin: .openverse, id: id, title: (title?.isEmpty == false ? title! : "Untitled"), creator: creator,
                license: license.lowercased(), licenseVersion: license_version, licenseURL: license_url,
                source: source ?? provider ?? "openverse", landingURL: foreign_landing_url, fileURL: url,
                fileType: filetype?.lowercased(), seconds: duration.map { Double($0) / 1000 }, fileSize: filesize,
                attribution: attribution)
        }
    }
}
