import Foundation

/// What preparing the macOS runner image costs, said up front so nobody finds
/// out an hour in. The numbers are for the default tart base image; a base
/// with Xcode is larger.
enum ImagePrepCost {
    static let macOSDiskGB = 60
    static var macOSTimeEstimate: String {
        String(
            localized: "20 to 60 minutes", bundle: .l10n,
            comment: "Estimated time to prepare the macOS image, shown inside a sentence")
    }

    /// Shown beside the base-image row until the image exists.
    static var notice: String {
        String(
            localized:
                "Preparing the macOS image downloads and stores about \(macOSDiskGB) GB and takes roughly \(macOSTimeEstimate), once. You can start the fleet while it runs: it continues in the background and macOS jobs begin when it finishes. Linux runtimes are much smaller.",
            bundle: .l10n,
            comment:
                "Notice beside the base-image row; the number is the download size in GB, then a time estimate phrase")
    }
}
