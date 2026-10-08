import Foundation

/// What preparing the macOS runner image costs, said up front so nobody finds
/// out an hour in. The numbers are for the default tart base image; a base
/// with Xcode is larger.
enum ImagePrepCost {
    static let macOSDiskGB = 60
    static let macOSTimeEstimate = "20 to 60 minutes"

    /// Shown beside the base-image row until the image exists.
    static var notice: String {
        "Preparing the macOS image downloads and stores about \(macOSDiskGB) GB and takes roughly "
            + "\(macOSTimeEstimate), once. You can start the fleet while it runs: it continues in the background "
            + "and macOS jobs begin when it finishes. Linux runtimes are much smaller."
    }
}
