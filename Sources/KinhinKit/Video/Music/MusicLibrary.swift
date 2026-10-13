import CryptoKit
import Foundation

/// Where a downloaded track came from: written beside the audio file so anyone can see its license and source later.
public struct MusicSidecar: Codable, Equatable, Sendable {
    public var file: String
    public var title: String
    public var creator: String?
    public var license: String
    public var licenseURL: String?
    public var source: String
    public var landingURL: String?
    public var openverseID: String
    public var sha256: String
    /// The credit line, when the license requires one.
    public var credit: String?
}

/// The tracks kept in a repository's `.kinhin/videos/music/`: saving a download with its provenance, and listing what is there.
public struct MusicLibrary: Sendable {
    public static let folder = "\(VideoProjects.folder)/music"
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "flac", "ogg"]
    /// Large enough for a few minutes of music, small enough that a wrong link cannot fill a disk.
    public static let maxBytes = 50 * 1024 * 1024

    let session: URLSession

    public init(session: URLSession = OpenverseClient.makeSession()) {
        self.session = session
    }

    public static func directory(in repo: URL) -> URL {
        repo.appendingPathComponent(folder, isDirectory: true)
    }

    /// `Calm Piano (loop) #2` becomes `calm-piano-loop-2`.
    public static func slug(_ title: String) -> String {
        var name = title.lowercased()
        // A title that is a file name (`Piano Loop.wav`) would otherwise end in `-wav`.
        for ext in audioExtensions where name.hasSuffix("." + ext) { name = String(name.dropLast(ext.count + 1)) }
        var out = ""
        var lastDash = true
        for scalar in name.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        out = String(out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(48))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "track" : out
    }

    /// The file extension to save under: the library's `filetype`, else the URL's, if it is one the pipeline can mix.
    static func fileExtension(for track: MusicTrack, url: URL) -> String? {
        let candidates = [track.fileType, url.pathExtension].compactMap { $0?.lowercased() }
        return candidates.first { Self.audioExtensions.contains($0) }
    }

    /// A name that does not collide with a saved track: `slug`, then `slug-2`, `slug-3`.
    static func uniqueName(slug: String, ext: String, in directory: URL) -> String {
        var name = slug
        var n = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(name).\(ext)").path)
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(name).json").path)
        {
            name = "\(slug)-\(n)"
            n += 1
        }
        return name
    }

    /// https only. A debug build running against a stand-in library (`KINHIN_OPENVERSE_URL`) may also fetch from that same host.
    static func isAllowedScheme(_ url: URL) -> Bool {
        if url.scheme == "https" { return true }
        #if DEBUG
            if url.scheme == "http", let standIn = URL(string: OpenverseClient.endpoint), standIn.host == url.host,
                standIn.port == url.port
            {
                return true
            }
        #endif
        return false
    }

    /// Downloads the audio to `destination`, refusing anything that is not https, too large, or not audio kinhin can mix.
    func download(_ track: MusicTrack, to destination: URL) async throws -> (file: URL, sha256: String) {
        guard let fileURL = track.fileURL, let url = URL(string: fileURL), Self.isAllowedScheme(url), url.host != nil
        else {
            throw MusicError.downloadRefused("its link is not https")
        }
        if let size = track.fileSize, size > Self.maxBytes {
            throw MusicError.downloadRefused(
                "it is \(size / 1_048_576) MB; the limit is \(Self.maxBytes / 1_048_576) MB")
        }
        guard let ext = Self.fileExtension(for: track, url: url) else {
            throw MusicError.downloadRefused(
                "its format (\(track.fileType ?? url.pathExtension)) is not mp3, m4a, wav, flac or ogg")
        }
        var request = URLRequest(url: url)
        request.setValue(OpenverseClient.userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: HTTPSOnlyRedirects())
        } catch {
            if error is CancellationError { throw error }
            throw MusicError.downloadRefused(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MusicError.downloadRefused("the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard data.count <= Self.maxBytes else {
            throw MusicError.downloadRefused("it is larger than \(Self.maxBytes / 1_048_576) MB")
        }
        guard !data.isEmpty else { throw MusicError.downloadRefused("the file is empty") }
        let directory = destination
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = Self.uniqueName(slug: Self.slug(track.title), ext: ext, in: directory)
        let file = directory.appendingPathComponent("\(name).\(ext)")
        try data.write(to: file, options: .withoutOverwriting)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (file, digest)
    }

    /// Saves `track` into `<repo>/.kinhin/videos/music/` with its provenance beside it.
    public func save(_ track: MusicTrack, in repo: URL) async throws -> (file: URL, sidecar: URL, credit: String?) {
        let (file, digest) = try await download(track, to: Self.directory(in: repo))
        let credit = MusicLicense.needsCredit(track.license) ? track.creditLine : nil
        let sidecar = MusicSidecar(
            file: file.lastPathComponent, title: track.title, creator: track.creator, license: track.license,
            licenseURL: track.licenseURL, source: track.source, landingURL: track.landingURL, openverseID: track.id,
            sha256: digest, credit: credit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let sidecarURL = file.deletingPathExtension().appendingPathExtension("json")
        try (encoder.encode(sidecar) + Data("\n".utf8)).write(to: sidecarURL, options: .withoutOverwriting)
        return (file, sidecarURL, credit)
    }

    /// The tracks saved in `repo`, by their provenance files.
    public static func saved(in repo: URL) -> [MusicSidecar] {
        let directory = Self.directory(in: repo)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(MusicSidecar.self, from: $0) }
        }.sorted { $0.file < $1.file }
    }
}

/// A download may be redirected (Freesound's CDN does), but never to plain http.
final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(MusicLibrary.isAllowedScheme) == true ? request : nil)
    }
}
