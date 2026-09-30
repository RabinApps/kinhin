import AppKit
import KinhinKit
import SwiftUI

// MARK: - Loader

/// Each forge's brand mark, a single-color template SVG from
/// `Resources/ForgeIcons` (see its README for provenance).
///
/// The images live in SwiftPM's resource bundle, found by hand instead of via
/// `Bundle.module`: that accessor traps when the bundle is missing, and the
/// app bundle is assembled by `scripts/build-app.sh`, not Xcode.
@MainActor
enum ForgeIcon {
    static let bundleName = "kinhin_kinhin-app.bundle"

    private static var cache: [ForgeID: NSImage] = [:]
    private static var missing: Set<ForgeID> = []
    private static let bundle = locateBundle()

    /// The forge's template image, or nil when it cannot be loaded (logged
    /// once per forge).
    static func nsImage(for forge: ForgeID) -> NSImage? {
        if let image = cache[forge] { return image }
        guard !missing.contains(forge) else { return nil }
        guard let url = bundle?.url(forResource: forge.rawValue, withExtension: "svg", subdirectory: "ForgeIcons"),
            let image = NSImage(contentsOf: url)
        else {
            missing.insert(forge)
            Log.warn("app", "no icon for forge '\(forge.rawValue)' (\(bundleName) not found or incomplete)")
            return nil
        }
        image.isTemplate = true
        // Menu-sized by default (the Picker's menu draws the intrinsic size);
        // ForgeIconView resizes it anyway.
        image.size = NSSize(width: 16, height: 16)
        image.accessibilityDescription = forge.displayName
        cache[forge] = image
        return image
    }

    /// The resource bundle: inside the .app's Resources, next to the
    /// executable (`swift run`), or next to the test bundle (`swift test`).
    static func locateBundle(candidates: [URL?] = defaultSearchDirectories) -> Bundle? {
        for directory in candidates.compactMap({ $0 }) {
            let url = directory.appendingPathComponent(bundleName)
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }

    /// A SwiftUI image for places that take a plain `Image` (menu items).
    static func image(for forge: ForgeID) -> Image {
        nsImage(for: forge).map { Image(nsImage: $0).renderingMode(.template) } ?? Image(systemName: "shippingbox")
    }

    static var defaultSearchDirectories: [URL?] {
        [
            Bundle.main.resourceURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent(),
        ]
    }

    private final class BundleToken {}
}

// MARK: - View

/// A forge's brand mark tinted like the surrounding text; falls back to a
/// generic symbol when the image is unavailable (the icon is decorative).
struct ForgeIconView: View {
    let forge: ForgeID
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let image = ForgeIcon.nsImage(for: forge) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "shippingbox")
                    .resizable()
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
