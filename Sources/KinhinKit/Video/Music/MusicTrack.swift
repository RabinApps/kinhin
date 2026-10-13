import Foundation

/// A track kinhin can put under a video: a result from the online library, or one of the built-in catalog.
public struct MusicTrack: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable {
        /// In the video image's catalog (`music.track: first-light-particles`): nothing to download.
        case builtIn
        /// A result from Openverse, downloaded into the repository when added.
        case openverse
    }

    public var origin: Origin
    /// Openverse's id (a UUID), or the catalog name for a built-in track.
    public var id: String
    public var title: String
    public var creator: String?
    /// Openverse's license code: `cc0`, `pdm`, `by`, ...
    public var license: String
    public var licenseVersion: String?
    public var licenseURL: String?
    /// Where it came from (`freesound`, `wikimedia_audio`, `opengameart`).
    public var source: String
    /// The page a person can listen to it and read its terms on.
    public var landingURL: String?
    /// The audio file itself.
    public var fileURL: String?
    public var fileType: String?
    public var seconds: Double?
    public var fileSize: Int?
    /// The credit line the source gives for it.
    public var attribution: String?
    /// A short description, for built-in tracks.
    public var summary: String?

    public init(
        origin: Origin, id: String, title: String, creator: String? = nil, license: String,
        licenseVersion: String? = nil, licenseURL: String? = nil, source: String, landingURL: String? = nil,
        fileURL: String? = nil, fileType: String? = nil, seconds: Double? = nil, fileSize: Int? = nil,
        attribution: String? = nil, summary: String? = nil
    ) {
        self.origin = origin
        self.id = id
        self.title = title
        self.creator = creator
        self.license = license
        self.licenseVersion = licenseVersion
        self.licenseURL = licenseURL
        self.source = source
        self.landingURL = landingURL
        self.fileURL = fileURL
        self.fileType = fileType
        self.seconds = seconds
        self.fileSize = fileSize
        self.attribution = attribution
        self.summary = summary
    }

    /// The credit a video description needs, for a license that requires one.
    public var creditLine: String {
        if let attribution, !attribution.isEmpty { return attribution }
        var line = "\"\(title)\""
        if let creator, !creator.isEmpty { line += " by \(creator)" }
        line += " is licensed under \(MusicLicense.displayName(license, version: licenseVersion))"
        if let licenseURL { line += " (\(licenseURL))" }
        return line
    }
}

/// Which licenses kinhin will put in a video: only ones that let anyone reuse the track. CC0 and the public domain need no
/// credit; CC BY is allowed on request and comes with the credit line it requires. Anything with a non-commercial,
/// no-derivatives or share-alike condition is refused.
public enum MusicLicense {
    public static let noCredit: Set<String> = ["cc0", "pdm"]
    public static let withCredit: Set<String> = ["by"]

    public static func isAllowed(_ license: String, allowAttribution: Bool) -> Bool {
        let code = license.lowercased()
        return noCredit.contains(code) || (allowAttribution && withCredit.contains(code))
    }

    public static func needsCredit(_ license: String) -> Bool {
        withCredit.contains(license.lowercased())
    }

    /// The license codes to ask the library for.
    public static func searchCodes(allowAttribution: Bool) -> [String] {
        allowAttribution ? ["cc0", "pdm", "by"] : ["cc0", "pdm"]
    }

    public static func displayName(_ license: String, version: String?) -> String {
        let name: String
        switch license.lowercased() {
        case "cc0": name = "CC0"
        case "pdm": name = "Public Domain Mark"
        case let other: name = "CC " + other.uppercased()
        }
        guard let version, !version.isEmpty else { return name }
        return "\(name) \(version)"
    }
}

/// What can go wrong finding, adding or listing music.
public enum MusicError: LocalizedError, Equatable {
    case emptyQuery
    case noSearchYet(String)
    case notFound(String)
    case licenseNotAllowed(title: String, license: String)
    case needsVideo([String])
    case noVideos
    case rateLimited(retryAfter: Int?)
    case network(String)
    case downloadRefused(String)

    public var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "search for what? For example: kinhin video music search \"calm piano\""
        case .noSearchYet(let reference):
            return "\"\(reference)\" is not a number from a search yet. Run `kinhin video music search <words>` first"
        case .notFound(let what):
            return "no track \"\(what)\": use a number from the last search, a built-in name, or an Openverse id"
        case .licenseNotAllowed(let title, let license):
            let code = license.isEmpty ? "unknown" : license.uppercased()
            return "\"\(title)\" is licensed \(code), which kinhin does not put in a video. "
                + "It allows CC0 and public domain, and CC BY with --license cc-by"
        case .needsVideo(let names):
            return "which video? Add --video <name>: \(names.joined(separator: ", "))"
        case .noVideos:
            return "there is no video in \(VideoProjects.folder)/ to add it to. "
                + "Run `kinhin video init` first, or use --no-config to just download it"
        case .rateLimited(let retryAfter):
            let wait = retryAfter.map { " Try again in \($0) seconds." } ?? " Try again in a minute."
            return "the music library is rate limiting this machine (200 searches a day without an account)." + wait
        case .network(let why):
            return "could not reach the music library: \(why)"
        case .downloadRefused(let why):
            return "did not download the track: \(why)"
        }
    }
}
