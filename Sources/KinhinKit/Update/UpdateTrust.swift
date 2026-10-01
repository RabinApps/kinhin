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

    static func isValidTeamID(_ id: String) -> Bool {
        id.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil
    }

    /// Code requirement for `codesign -R`: Apple-issued Developer ID chain
    /// whose leaf certificate belongs to `teamID`.
    static func requirement(teamID: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// The Developer ID Team ID the running binary is signed with; nil for
    /// ad-hoc or unsigned builds (forks, local builds, `swift test`), where
    /// there is nothing to pin the update to.
    public static func currentTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
            let dict = info as? [String: Any],
            let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
            isValidTeamID(team)
        else { return nil }
        return team
    }
}
