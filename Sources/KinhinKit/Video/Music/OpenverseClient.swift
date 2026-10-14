import Foundation
import Synchronization

/// Searches Openverse (openverse.org), one index of openly licensed audio from Freesound, Wikimedia Commons and others.
/// No account or key is needed; anonymous use is limited to 20 requests a minute and 200 a day. A registered Openverse
/// application (`KINHIN_OPENVERSE_CLIENT_ID` and `KINHIN_OPENVERSE_CLIENT_SECRET` in the environment) gets a higher allowance:
/// the client then signs in with the client-credentials grant and sends a bearer token.
public struct OpenverseClient: Sendable {
    /// A registered Openverse application.
    public struct Credentials: Equatable, Sendable {
        public let clientID: String
        public let clientSecret: String

        public init(clientID: String, clientSecret: String) {
            self.clientID = clientID
            self.clientSecret = clientSecret
        }

        /// From `KINHIN_OPENVERSE_CLIENT_ID` and `KINHIN_OPENVERSE_CLIENT_SECRET`; nil unless both are set.
        public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment)
            -> Credentials?
        {
            guard let id = environment["KINHIN_OPENVERSE_CLIENT_ID"], !id.isEmpty,
                let secret = environment["KINHIN_OPENVERSE_CLIENT_SECRET"], !secret.isEmpty
            else { return nil }
            return Credentials(clientID: id, clientSecret: secret)
        }
    }

    /// The bearer token, kept for the life of the process (Openverse issues them for about twelve hours). Callers that arrive
    /// while a sign-in is running wait for it instead of starting their own.
    private final class TokenCache: Sendable {
        private struct State {
            var stored: (token: String, expires: Date)?
            var pending: Task<String, Error>?
        }

        private let state = Mutex(State())

        func current(now: Date) -> String? {
            state.withLock { $0.stored.flatMap { $0.expires > now ? $0.token : nil } }
        }

        func store(_ token: String, expires: Date) {
            state.withLock { $0.stored = (token, expires) }
        }

        func signIn(_ start: @escaping @Sendable () async throws -> String) async throws -> String {
            let task: Task<String, Error> = state.withLock { state in
                if let pending = state.pending { return pending }
                let created = Task { try await start() }
                state.pending = created
                return created
            }
            defer { state.withLock { $0.pending = nil } }
            return try await task.value
        }
    }

    public static let productionEndpoint = "https://api.openverse.org/v1/audio/"

    /// The library's address. A debug build honors `KINHIN_OPENVERSE_URL` (a stand-in server for the end-to-end tests, which must
    /// not depend on the public service); a release build never reads it.
    public static var endpoint: String {
        #if DEBUG
            if let override = ProcessInfo.processInfo.environment["KINHIN_OPENVERSE_URL"], !override.isEmpty {
                return override.hasSuffix("/") ? override : override + "/"
            }
        #endif
        return productionEndpoint
    }

    let session: URLSession
    let credentials: Credentials?
    private let tokens = TokenCache()

    public init(
        session: URLSession = OpenverseClient.makeSession(), credentials: Credentials? = Credentials.fromEnvironment()
    ) {
        self.session = session
        self.credentials = credentials
    }

    /// Results per page: the anonymous maximum, or more with credentials.
    var pageSize: Int { credentials == nil ? Self.anonymousPageSize : Self.registeredPageSize }
    public static let registeredPageSize = 50

    /// Where the token is requested: beside the audio endpoint (`.../v1/audio/` -> `.../v1/auth_tokens/token/`).
    static var tokenEndpoint: String {
        let audio = endpoint
        let base = audio.hasSuffix("audio/") ? String(audio.dropLast("audio/".count)) : audio
        return base + "auth_tokens/token/"
    }

    /// A bearer token for the registered application, or nil when there are no credentials.
    func accessToken() async throws -> String? {
        guard let credentials else { return nil }
        if let token = tokens.current(now: Date()) { return token }
        return try await tokens.signIn { try await requestToken(credentials) }
    }

    private func requestToken(_ credentials: Credentials) async throws -> String {
        guard let url = URL(string: Self.tokenEndpoint) else { throw MusicError.network("bad token address") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "client_secret", value: credentials.clientSecret),
        ]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            if error is CancellationError { throw error }
            throw MusicError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw MusicError.network("no answer") }
        guard http.statusCode == 200 else {
            if http.statusCode == 400 || http.statusCode == 401 || http.statusCode == 403 {
                throw MusicError.network(
                    "Openverse did not accept KINHIN_OPENVERSE_CLIENT_ID and KINHIN_OPENVERSE_CLIENT_SECRET (HTTP \(http.statusCode))"
                )
            }
            throw MusicError.network("HTTP \(http.statusCode) from the Openverse sign-in")
        }
        struct TokenBody: Decodable {
            var access_token: String
            var expires_in: Double?
        }
        // the else branch reports an undecodable token reply as MusicError.network
        guard let body = try? JSONDecoder().decode(TokenBody.self, from: data), !body.access_token.isEmpty else {
            throw MusicError.network(
                "unexpected answer from the Openverse sign-in: \(String(decoding: data.prefix(120), as: UTF8.self))")
        }
        // Renew a minute early.
        tokens.store(body.access_token, expires: Date().addingTimeInterval(max(60, (body.expires_in ?? 3600) - 60)))
        return body.access_token
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
        let url = try Self.searchURL(
            endpoint: Self.endpoint, query: query, licenses: licenses, pageSize: pageSize, page: page)
        let data = try await fetch(url, pastTheEndIsEmpty: true)
        let page: SearchPage
        do { page = try JSONDecoder().decode(SearchPage.self, from: data) } catch {
            throw MusicError.network("unexpected answer")
        }
        return page.results.compactMap(\.track)
    }

    /// The search request's address. Throws when `endpoint` (which a debug build may take from `KINHIN_OPENVERSE_URL`) is
    /// not a URL.
    static func searchURL(endpoint: String, query: String, licenses: [String], pageSize: Int, page: Int) throws -> URL {
        guard var components = URLComponents(string: endpoint) else {
            throw MusicError.network("bad search address: \(endpoint)")
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "license", value: licenses.joined(separator: ",")),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "mature", value: "false"),
        ]
        guard let url = components.url else { throw MusicError.network("bad search address: \(endpoint)") }
        return url
    }

    /// One result by its Openverse id.
    public func detail(id: String) async throws -> MusicTrack {
        guard let url = URL(string: Self.endpoint + id + "/"), UUID(uuidString: id) != nil else {
            throw MusicError.notFound(id)
        }
        let data = try await fetch(url, pastTheEndIsEmpty: false)
        // the else branch reports an undecodable track as MusicError.notFound
        guard let track = (try? JSONDecoder().decode(Result.self, from: data))?.track else {
            throw MusicError.notFound(id)
        }
        return track
    }

    private func fetch(_ url: URL, pastTheEndIsEmpty: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = try await accessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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
            // an error body is optional detail; the HTTP status is reported either way
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
                origin: .openverse, id: id, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled",
                creator: creator,
                license: license.lowercased(), licenseVersion: license_version, licenseURL: license_url,
                source: source ?? provider ?? "openverse", landingURL: foreign_landing_url, fileURL: url,
                fileType: filetype?.lowercased(), seconds: duration.map { Double($0) / 1000 }, fileSize: filesize,
                attribution: attribution)
        }
    }
}
