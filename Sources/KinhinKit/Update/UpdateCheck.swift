import Foundation

/// Everything the UI needs to know about the latest GitHub release.
public struct UpdateInfo: Equatable, Sendable {
    public let tag: String
    public let version: String  // "1.2.3" without the leading "v"
    public let dmgName: String
    let dmgURL: URL
    let releaseURL: URL
    let publishedAt: Date?
    let notes: String?

    public init(
        tag: String, version: String, dmgName: String, dmgURL: URL, releaseURL: URL, publishedAt: Date?, notes: String?
    ) {
        self.tag = tag
        self.version = version
        self.dmgName = dmgName
        self.dmgURL = dmgURL
        self.releaseURL = releaseURL
        self.publishedAt = publishedAt
        self.notes = notes
    }
}

/// The result of comparing the running kinhin against the latest GitHub release.
public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case available(UpdateInfo)
}

enum UpdateCheckError: LocalizedError, Equatable {
    case notFound(String)
    case noDMGAsset(String)
    case http(Int, String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let repo):
            return "No releases found for \(repo) — has a v* tag been pushed?"
        case .noDMGAsset(let release):
            return "Release \(release) contains no kinhin-*-arm64.dmg asset"
        case .http(let code, let body):
            return "Update check HTTP \(code): \(body)"
        case .decoding(let why):
            return "Could not decode release info: \(why)"
        }
    }
}

/// Compares dotted release versions: `1.0.0` < `1.0.1`, `1.0` == `1.0.0`,
/// and a pre-release suffix sorts *below* the bare version, so
/// `1.0.0-beta` < `1.0.0` holds.
func isVersion(_ a: String, olderThan b: String) -> Bool {
    let left = a.split(separator: ".").map(String.init)
    let right = b.split(separator: ".").map(String.init)
    // Split a segment into its numeric prefix and any pre-release suffix.
    func parts(_ s: String) -> (Int, String) {
        let digits = s.prefix(while: { $0.isNumber })
        return (Int(digits) ?? -1, String(s.dropFirst(digits.count)))
    }
    for i in 0..<max(left.count, right.count) {
        let l = i < left.count ? left[i] : "0"
        let r = i < right.count ? right[i] : "0"
        let (li, ls) = parts(l)
        let (ri, rs) = parts(r)
        if li != ri { return li < ri }
        if ls.isEmpty != rs.isEmpty { return !ls.isEmpty }  // "-beta" < ""
        if ls != rs { return ls < rs }
    }
    return false
}

/// Checks GitHub for a newer kinhin release. Network errors are surfaced as
/// thrown errors so the caller decides whether to stay silent; the comparison
/// itself is pure and unit-tested.
public struct UpdateChecker: Sendable {
    public let repo: String  // "RabinApps/name"
    let currentVersion: String
    let session: URLSession

    public init(repo: String, currentVersion: String = kinhinVersion.current, session: URLSession? = nil) {
        self.repo = repo
        self.currentVersion = currentVersion
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)
        }
    }

    static func dmgAssetName(forVersion version: String) -> String {
        "kinhin-\(version)-arm64.dmg"
    }

    /// Fetch the latest release and compare against `currentVersion`.
    public func check() async throws -> UpdateCheckResult {
        let info = try await fetchLatestRelease()
        guard isVersion(currentVersion, olderThan: info.version) else {
            return .upToDate
        }
        return .available(info)
    }

    /// Query releases/latest and build UpdateInfo from the DMG asset.
    func fetchLatestRelease() async throws -> UpdateInfo {
        guard repo.split(separator: "/").count == 2 else {
            throw UpdateCheckError.notFound(repo)
        }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.httpMethod = "GET"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Kinhin/1.0 (update-check)", forHTTPHeaderField: "User-Agent")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.http(0, "non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 404 {
                throw UpdateCheckError.notFound(repo)
            }
            throw UpdateCheckError.http(http.statusCode, String(decoding: data.prefix(500), as: UTF8.self))
        }

        struct ReleaseResponse: Codable {
            struct Asset: Codable {
                let name: String
                let browser_download_url: URL
            }
            struct Author: Codable { let login: String }
            let tag_name: String
            let name: String?
            let html_url: URL
            let published_at: Date?
            let body: String?
            let assets: [Asset]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release: ReleaseResponse
        do {
            release = try decoder.decode(ReleaseResponse.self, from: data)
        } catch {
            throw UpdateCheckError.decoding("releases/latest: \(error.localizedDescription)")
        }

        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        let wanted = Self.dmgAssetName(forVersion: version)
        guard
            let dmg = release.assets.first(where: { $0.name == wanted })
                ?? release.assets.first(where: { $0.name.hasSuffix("-arm64.dmg") })
        else {
            throw UpdateCheckError.noDMGAsset(release.tag_name)
        }
        return UpdateInfo(
            tag: release.tag_name,
            version: version,
            dmgName: dmg.name,
            dmgURL: dmg.browser_download_url,
            releaseURL: release.html_url,
            publishedAt: release.published_at,
            notes: release.body
        )
    }

    /// Stream a release DMG to a temp file. URLSession downloads do not set the
    /// quarantine attribute, so the mounted DMG opens without Gatekeeper
    /// prompts — same effect as `curl -O`. Caller must remove the file when done.
    public func downloadDMG(_ info: UpdateInfo, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-update-\(info.dmgName)")
        try? FileManager.default.removeItem(at: temp)

        let delegate = DownloadProgressDelegate(progress: progress)
        let (location, response) = try await session.download(for: URLRequest(url: info.dmgURL), delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)
            throw UpdateCheckError.http(http.statusCode, "downloading \(info.dmgName)")
        }
        try FileManager.default.moveItem(at: location, to: temp)
        return temp
    }
}

/// Bridges URLSession download progress to a closure.
final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: (@Sendable (Double) -> Void)?

    init(progress: (@Sendable (Double) -> Void)?) {
        self.progress = progress
    }

    func urlSession(
        _: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo _: URL) {}
}
