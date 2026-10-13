import CryptoKit
import Foundation

/// Everything the UI needs to know about the latest GitHub release.
public struct UpdateInfo: Equatable, Sendable {
    public let tag: String
    public let version: String  // "1.2.3" without the leading "v"
    public let dmgName: String
    let dmgURL: URL
    /// The release's `checksums.txt` asset; nil when the release has none.
    let checksumsURL: URL?
    let releaseURL: URL
    let publishedAt: Date?
    let notes: String?

    public init(
        tag: String, version: String, dmgName: String, dmgURL: URL, checksumsURL: URL? = nil, releaseURL: URL,
        publishedAt: Date?, notes: String?
    ) {
        self.tag = tag
        self.version = version
        self.dmgName = dmgName
        self.dmgURL = dmgURL
        self.checksumsURL = checksumsURL
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
    case noChecksum(String)
    case checksumMismatch(String)
    case invalidRepo(String)
    case untrustedAsset(String)
    case signatureInvalid(String)
    case notarizationRejected(String)
    case signingUnreadable
    case invalidTag(String)
    case responseTooLarge(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let repo):
            return "No releases found for \(repo) — has a v* tag been pushed?"
        case .noDMGAsset(let release):
            return "Release \(release) contains no kinhin-*-arm64.dmg asset"
        case .http(let code, let body):
            return "Update check HTTP \(code): \(body)"
        case .decoding(let why):
            return "Could not decode release info: \(why)"
        case .noChecksum(let name):
            return "Release has no checksum for \(name); refusing to install an unverified update"
        case .checksumMismatch(let name):
            return "Downloaded \(name) does not match the release checksum; the file was discarded"
        case .invalidRepo(let repo):
            return "'\(repo)' is not a valid owner/name GitHub repository"
        case .untrustedAsset(let name):
            return "Release asset \(name) is not served from the release's own download URL; refusing it"
        case .signatureInvalid(let name):
            return "\(name) is not signed by the same Developer ID as this app; the file was discarded"
        case .notarizationRejected(let name):
            return "Gatekeeper rejected \(name) (not notarized or revoked); the file was discarded"
        case .signingUnreadable:
            return
                "Could not read this app's code signature, so an update cannot be verified; reinstall kinhin manually"
        case .invalidTag(let tag):
            return "Release tag '\(tag)' is not of the form vMAJOR.MINOR.PATCH; refusing it"
        case .responseTooLarge(let what):
            return "\(what) is unexpectedly large; refusing it"
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
        // Numeric-aware so `-beta-2` < `-beta-10`.
        if ls != rs { return ls.compare(rs, options: .numeric) == .orderedAscending }
    }
    return false
}

/// Checks GitHub for a newer kinhin release. Network errors are surfaced as
/// thrown errors so the caller decides whether to stay silent; the comparison
/// itself is pure and unit-tested.
public struct UpdateChecker: Sendable {
    public let repo: String  // "owner/name"
    let currentVersion: String
    let session: URLSession
    let shell: any ShellRunning
    /// How the running build is signed. A Developer ID build only accepts DMGs
    /// signed by its own team; an ad-hoc build (nothing to pin to) falls back to
    /// the checksum; an unreadable signature refuses every update.
    let signing: UpdateTrust.Signing
    /// Where each download gets its own private directory: the system temp directory, except in tests, which use a directory
    /// of their own so tests running in parallel processes cannot see (or clear) each other's downloads.
    let downloadRoot: URL

    public init(
        repo: String, currentVersion: String = kinhinVersion.current, session: URLSession? = nil,
        shell: any ShellRunning = Shell(), signing: UpdateTrust.Signing = UpdateTrust.currentSigning(),
        downloadRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.downloadRoot = downloadRoot
        self.repo = repo
        self.currentVersion = currentVersion
        self.shell = shell
        self.signing = signing
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            // Redirects may only stay on GitHub's own hosts.
            self.session = URLSession(configuration: config, delegate: UpdateRedirectGuard(), delegateQueue: nil)
        }
    }

    /// For tests and callers that only know the team: nil means ad-hoc.
    public init(
        repo: String, currentVersion: String = kinhinVersion.current, session: URLSession? = nil,
        shell: any ShellRunning = Shell(), trustedTeamID: String?,
        downloadRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.init(
            repo: repo, currentVersion: currentVersion, session: session, shell: shell,
            signing: trustedTeamID.map { .developerID(teamID: $0) } ?? .adHoc, downloadRoot: downloadRoot)
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

    /// Query releases/latest and build UpdateInfo from the DMG asset. A beta build
    /// lists releases instead, because `/releases/latest` never returns pre-releases.
    func fetchLatestRelease() async throws -> UpdateInfo {
        guard UpdateTrust.isValidRepo(repo) else {
            throw UpdateCheckError.invalidRepo(repo)
        }
        let listsPrereleases = currentVersion.contains("-")
        let endpoint = listsPrereleases ? "releases?per_page=1" : "releases/latest"
        guard let releaseURL = URL(string: "https://api.github.com/repos/\(repo)/\(endpoint)") else {
            throw UpdateCheckError.notFound(repo)
        }
        var req = URLRequest(url: releaseURL)
        req.httpMethod = "GET"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Kinhin/1.0 (update-check)", forHTTPHeaderField: "User-Agent")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: req)
        guard data.count <= UpdateTrust.maxMetadataBytes else {
            throw UpdateCheckError.responseTooLarge("the release response")
        }
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
            if listsPrereleases {
                guard let newest = try decoder.decode([ReleaseResponse].self, from: data).first else {
                    throw UpdateCheckError.notFound(repo)
                }
                release = newest
            } else {
                release = try decoder.decode(ReleaseResponse.self, from: data)
            }
        } catch let error as UpdateCheckError {
            throw error
        } catch {
            throw UpdateCheckError.decoding("releases/latest: \(error.localizedDescription)")
        }

        guard UpdateTrust.isValidReleaseTag(release.tag_name) else {
            throw UpdateCheckError.invalidTag(release.tag_name)
        }
        let version = String(release.tag_name.dropFirst())
        // Exactly the DMG for this version: a differently named (or older) DMG
        // attached to a new tag must not be offered as the update.
        let wanted = Self.dmgAssetName(forVersion: version)
        guard let dmg = release.assets.first(where: { $0.name == wanted }) else {
            throw UpdateCheckError.noDMGAsset(release.tag_name)
        }
        guard UpdateTrust.isSafeAssetName(dmg.name),
            UpdateTrust.isTrustedDownloadURL(dmg.browser_download_url, repo: repo)
        else {
            throw UpdateCheckError.untrustedAsset(dmg.name)
        }
        // A checksums URL outside the release is dropped, which fails closed
        // later (`noChecksum`) instead of trusting a foreign host.
        let checksums = release.assets
            .first(where: {
                $0.name == "checksums.txt" && UpdateTrust.isTrustedDownloadURL($0.browser_download_url, repo: repo)
            })?
            .browser_download_url
        return UpdateInfo(
            tag: release.tag_name,
            version: version,
            dmgName: dmg.name,
            dmgURL: dmg.browser_download_url,
            checksumsURL: checksums,
            releaseURL: release.html_url,
            publishedAt: release.published_at,
            notes: release.body
        )
    }

    /// Stream a release DMG to a temp file, then verify its checksum and (for
    /// Developer ID builds) that it is signed by the running app's Team ID.
    /// URLSession downloads carry no quarantine attribute; the signature
    /// check is what stands in for Gatekeeper here. Caller must remove the
    /// file when done.
    public func downloadDMG(_ info: UpdateInfo, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        guard UpdateTrust.isSafeAssetName(info.dmgName) else {
            throw UpdateCheckError.untrustedAsset(info.dmgName)
        }
        Self.removeStaleDownloads(in: downloadRoot)
        // A fresh private directory per download: nothing else can pre-create or
        // swap the file between verification and the moment it is opened.
        let directory =
            downloadRoot
            .appendingPathComponent("\(Self.downloadDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)
        try Paths.createPrivateDirectory(directory)
        let temp = directory.appendingPathComponent(info.dmgName)

        let delegate = DownloadProgressDelegate(progress: progress)
        let (location, response) = try await session.download(for: URLRequest(url: info.dmgURL), delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)  // system temp file; the HTTP error is what matters
            bestEffort("update", "remove download directory") { try FileManager.default.removeItem(at: directory) }
            throw UpdateCheckError.http(http.statusCode, "downloading \(info.dmgName)")
        }
        do {
            try FileManager.default.moveItem(at: location, to: temp)
            try await verifyChecksum(of: temp, named: info.dmgName, checksumsURL: info.checksumsURL)
            try await verifySignature(of: temp, named: info.dmgName)
        } catch {
            // Never leave an unverified (or tampered) installer on disk.
            bestEffort("update", "remove unverified download") { try FileManager.default.removeItem(at: directory) }
            throw error
        }
        return temp
    }

    /// Requires the DMG to be signed by the Developer ID Team ID of the running
    /// app and accepted by Gatekeeper (notarized, not revoked). An ad-hoc build
    /// has no signer to pin to and relies on the checksum; a build whose own
    /// signature cannot be read refuses the update.
    func verifySignature(of file: URL, named name: String) async throws {
        let teamID: String
        switch signing {
        case .developerID(let team):
            teamID = team
        case .adHoc:
            Log.warn("update", "running build has no Developer ID; \(name) verified by checksum only")
            return
        case .unreadable:
            throw UpdateCheckError.signingUnreadable
        }
        let result = try await shell.run([
            "/usr/bin/codesign", "--verify", "--strict", "-R=\(UpdateTrust.requirement(teamID: teamID))", file.path,
        ])
        guard result.succeeded else {
            Log.error("update", "signature check failed for \(name): \(result.failureExcerpt)")
            throw UpdateCheckError.signatureInvalid(name)
        }
        // The file carries no quarantine attribute, so Gatekeeper never looked at it:
        // ask for the same assessment (notarization ticket, revocation) explicitly.
        let assessment = try await shell.run([
            "/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "-v", file.path,
        ])
        guard assessment.succeeded else {
            Log.error("update", "Gatekeeper assessment failed for \(name): \(assessment.failureExcerpt)")
            throw UpdateCheckError.notarizationRejected(name)
        }
    }

    static let downloadDirectoryPrefix = "kinhin-update-"

    /// Earlier downloads (and the old fixed-name files) are not needed once a
    /// new one starts; best effort, the system temp directory is cleaned anyway.
    static func removeStaleDownloads(in root: URL) {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(downloadDirectoryPrefix) {
            bestEffort("update", "remove old download \(entry.lastPathComponent)") { try fm.removeItem(at: entry) }
        }
    }

    /// Compares the file's SHA-256 with its line in the release's
    /// `checksums.txt` (`shasum -a 256` format). Fails closed: a release
    /// without a checksum entry is not installable through the updater.
    func verifyChecksum(of file: URL, named name: String, checksumsURL: URL?) async throws {
        guard let checksumsURL else { throw UpdateCheckError.noChecksum(name) }
        let (data, response) = try await session.data(from: checksumsURL)
        guard data.count <= UpdateTrust.maxMetadataBytes else {
            throw UpdateCheckError.responseTooLarge("checksums.txt")
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateCheckError.http(http.statusCode, "downloading checksums.txt")
        }
        guard let expected = Self.expectedChecksum(for: name, in: String(decoding: data, as: UTF8.self)) else {
            throw UpdateCheckError.noChecksum(name)
        }
        guard try Self.sha256Hex(of: file) == expected else {
            throw UpdateCheckError.checksumMismatch(name)
        }
    }

    /// Finds `name` in `shasum` output ("<hex>  <name>", optional `*` binary
    /// marker) and returns its lowercase digest.
    static func expectedChecksum(for name: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            let entry = fields[1].trimmingCharacters(in: .whitespaces)
            if entry == name || entry == "*" + name { return fields[0].lowercased() }
        }
        return nil
    }

    static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }  // read-only handle: a failed close loses nothing
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Refuses redirects that leave GitHub's hosts or drop to http. Used as the
/// session delegate and for the download task, so no step of an update can be
/// bounced to a host the release did not name.
final class UpdateRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if let url = request.url, UpdateTrust.isTrustedRedirectTarget(url) {
            completionHandler(request)
        } else {
            Log.warn("update", "refused a redirect to \(request.url?.host ?? "an unknown host")")
            completionHandler(nil)
        }
    }
}

/// Bridges URLSession download progress to a closure.
final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let redirectGuard = UpdateRedirectGuard()

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        redirectGuard.urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: request,
            completionHandler: completionHandler)
    }

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
