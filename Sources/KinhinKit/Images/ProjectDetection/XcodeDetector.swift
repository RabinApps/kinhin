import Foundation

/// Spots projects that need full Xcode. Xcode is far too large to install
/// from a script, so it is never a toolchain spec: the answer is a base
/// image that ships it (see `TartBaseImage.curated`).
enum XcodeDetector {
    /// The Xcode-flavoured base image to suggest.
    static let recommendedImage = "ghcr.io/cirruslabs/macos-tahoe-xcode:latest"

    /// Workflow text that means the build needs full Xcode (`xcrun` alone ships with the Command Line Tools).
    private static let workflowTokens = [
        "xcodebuild", "setup-xcode", "xcresulttool", "xcode-select -s", "xcode-select --switch",
    ]

    /// Where Xcode projects live: the root, plus the platform folders of Flutter and React Native.
    private static let projectFolders = ["", "ios", "macos"]

    struct Signal: Equatable {
        let source: String
        let reason: String
    }

    static func signals(in reader: ProjectFileReading) throws -> [Signal] {
        var out: [Signal] = []
        for folder in projectFolders {
            for name in try reader.list(folder) where name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") {
                let path = folder.isEmpty ? name : "\(folder)/\(name)"
                out.append(Signal(source: path, reason: "Xcode project"))
            }
        }
        if let version = try reader.text(".xcode-version") {
            out.append(Signal(source: ".xcode-version", reason: "pins Xcode \(version.trimmed())"))
        }
        // A package for an Apple platform other than macOS builds with xcodebuild;
        // a macOS-only or Linux-style package builds with plain `swift`.
        if let package = try reader.text("Package.swift"),
            [".iOS(", ".tvOS(", ".watchOS(", ".visionOS("].contains(where: package.contains)
        {
            out.append(Signal(source: "Package.swift", reason: "targets an Apple platform beyond macOS"))
        }
        for file in try reader.list(".github/workflows") where file.hasSuffix(".yml") || file.hasSuffix(".yaml") {
            let path = ".github/workflows/\(file)"
            if let text = try reader.text(path), let token = workflowTokens.first(where: text.contains) {
                out.append(Signal(source: path, reason: "calls \(token)"))
            }
        }
        return out
    }

    static func recommendation(for signals: [Signal]) -> String {
        let pin = signals.first { $0.source == ".xcode-version" }.map { " (\($0.reason))" } ?? ""
        return
            "Full Xcode is needed\(pin) and cannot be installed as a toolchain: set base_image: (or `image prepare --source`) to an image that includes it, such as \(recommendedImage)"
    }
}
