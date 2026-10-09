import Foundation

// MARK: - String Catalog bundle

extension Bundle {
    /// The bundle holding the app's String Catalog (`Resources/Localizable.xcstrings`).
    ///
    /// Pass it as `bundle: .l10n` to `String(localized:)` for every user-facing string built in code:
    ///
    ///     String(localized: "Install \(tool)?", bundle: .l10n, comment: "Alert title; tool is a package name")
    ///
    /// SwiftUI literals (`Text("…")`, `Button("…")`, …) resolve through `Bundle.main`, which
    /// `scripts/build-app.sh` fills with the catalog's `*.lproj` folders. Code can't rely on that: under
    /// `swift run` and `swift test` the catalog only exists in SwiftPM's resource bundle, which is
    /// found by hand (not via `Bundle.module`, which traps when the bundle is missing) exactly like
    /// the forge icons.
    static let l10n: Bundle = {
        let main = Bundle.main
        if main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en") != nil
            || main.url(forResource: "Localizable", withExtension: "stringsdict", subdirectory: nil, localization: "en")
                != nil
        {
            return main
        }
        let name = "kinhin_kinhin-app.bundle"
        let token = L10nBundleToken.self
        let directories: [URL?] = [
            main.resourceURL,
            main.executableURL?.deletingLastPathComponent(),
            Bundle(for: token).bundleURL.deletingLastPathComponent(),
        ]
        for directory in directories.compactMap({ $0 }) {
            if let bundle = Bundle(url: directory.appendingPathComponent(name)) { return bundle }
        }
        return main
    }()
}

private final class L10nBundleToken {}
