import Foundation
import Security

/// What the updater accepts from the release feed, and how a downloaded
/// installer is tied back to the signer of the running build.
///
/// A matching SHA-256 only proves the DMG is the one the release lists, so
/// anyone who can publish to the release can pair a tampered DMG with a
/// matching checksum. Pinning the Developer ID Team ID of the running app to
/// the DMG's signature closes that gap without shipping a second key.
public enum UpdateTrust {
    /// `owner/name` with the characters GitHub allows; keeps the repo from
    /// reshaping the API path (`..`, `?`, extra segments).
    static func isValidRepo(_ repo: String) -> Bool {
        guard repo.range(of: #"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            return false
        }
        // "." and ".." match the character class but navigate the API path.
        return !repo.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    /// A bare file name: no separators or traversal, so it is safe to splice
    /// into a temp path.
    static func isSafeAssetName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
            && !name.contains("..")
    }

    /// Release assets are served from github.com/<repo>/releases/download/…
    /// (which then redirects to GitHub's CDN); anything else in the API
    /// response is not a download we asked for.
    static func isTrustedDownloadURL(_ url: URL, repo: String) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "github.com" else { return false }
        let prefix = "/\(repo)/releases/download/"
        return url.path.lowercased().hasPrefix(prefix.lowercased()) && !url.path.contains("..")
    }

    /// The only release tag shapes the updater acts on: `vMAJOR.MINOR.PATCH`, optionally `-beta-N`.
    static func isValidReleaseTag(_ tag: String) -> Bool {
        tag.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+(-beta-[0-9]+)?$"#, options: .regularExpression) != nil
    }

    /// Hosts a release download may be redirected through: GitHub itself and the
    /// CDNs it serves release assets from. Everything else is refused.
    static func isTrustedRedirectTarget(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return ["github.com", "api.github.com"].contains(host) || host.hasSuffix(".githubusercontent.com")
    }

    /// Upper bound for the release JSON and `checksums.txt`; both are tiny.
    static let maxMetadataBytes = 2_000_000

    static func isValidTeamID(_ id: String) -> Bool {
        id.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil
    }

    /// Code requirement for `codesign -R`: the Developer ID chain (Developer ID
    /// CA plus a Developer ID Application leaf) whose leaf belongs to `teamID`.
    /// Pinning the leaf type keeps an Apple Development or Mac App Store
    /// certificate of the same team from satisfying it.
    static func requirement(teamID: String) -> String {
        "anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// How the running build is signed, which decides what the updater can pin.
    public enum Signing: Equatable, Sendable {
        /// Developer ID build: updates must be signed by this team.
        case developerID(teamID: String)
        /// Ad-hoc or unsigned (forks, local builds, `swift test`): nothing to pin to.
        case adHoc
        /// The signature could not be read at all. Treated as untrusted, never as ad-hoc.
        case unreadable
    }

    /// The Developer ID Team ID the running binary is signed with; nil for
    /// ad-hoc, unsigned or unreadable signatures.
    public static func currentTeamID() -> String? {
        if case .developerID(let team) = currentSigning() { return team }
        return nil
    }

    public static func currentSigning() -> Signing {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unreadable }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return .unreadable }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
            let dict = info as? [String: Any]
        else { return .unreadable }
        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String {
            return isValidTeamID(team) ? .developerID(teamID: team) : .unreadable
        }
        // Signed without a team: ad-hoc (or unsigned), which is normal for local builds.
        return .adHoc
    }
}
