import Foundation

/// The project shapes `kinhin mobile init` understands, named as the `--framework` flag spells them.
public enum MobileFramework: String, CaseIterable, Sendable {
    case auto
    case ios
    case android
    /// An iOS and Android project with no framework of its own (both folders present, or project files at the root).
    case native
    case flutter
    case reactNative = "react-native"
    case expo
}

/// What a scaffold run did, line by line, for the CLI to print.
public struct MobileScaffoldReport: Equatable, Sendable {
    public let framework: MobileFramework
    public let platforms: [String]
    public let lines: [String]
    public let dryRun: Bool
}

public enum MobileScaffoldError: Error, Equatable, LocalizedError {
    case noProject(directory: String)
    case noPlatformFolder(framework: MobileFramework, directory: String)
    case unreadableGemfile(path: String)
    case cannotWrite(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .noProject(let directory):
            return "no iOS or Android project in \(directory); pass --framework"
        case .noPlatformFolder(let framework, let directory):
            return "no ios/ or android/ folder in \(directory) for a \(framework.rawValue) project"
        case .unreadableGemfile(let path):
            return "\(path) exists but cannot be read"
        case .cannotWrite(let path, let reason):
            return "cannot write \(path): \(reason)"
        }
    }
}

/// Scaffolds fastlane (and the CI workflow) into a mobile project. Files that already exist are kept unless
/// `force` is set, so running it again is safe. The templates come from `MobileTemplates`, which
/// `MobileScaffoldTests` keeps equal to `templates/mobile/`.
public enum MobileScaffold {
    public static func run(
        in directory: URL, framework requested: MobileFramework, force: Bool, dryRun: Bool
    ) throws -> MobileScaffoldReport {
        let framework = requested == .auto ? try detect(in: directory) : requested
        let platforms = try platformsFor(framework, in: directory)
        var writer = Writer(root: directory, force: force, dryRun: dryRun)

        if framework == .expo {
            try writer.write(template: "expo/eas.json", to: "eas.json")
            writer.note("Expo uses EAS Build/Submit by default; no fastlane workflow is written.")
            writer.note("For fastlane, run 'npx expo prebuild' and re-run with --framework react-native.")
            return report(framework, platforms, writer)
        }

        try writer.gemfile()
        for platform in platforms {
            try writer.scaffoldFastlane(platform: platform, folder: platformFolder(platform, in: directory))
        }
        try writer.workflow(framework: framework, platforms: platforms, directory: directory)
        return report(framework, platforms, writer)
    }

    /// The framework a folder looks like, checked in order: Flutter, Expo, React Native, then the platform folders.
    public static func detect(in directory: URL) throws -> MobileFramework {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent("pubspec.yaml").path) { return .flutter }
        if packageJSON(in: directory).contains("\"expo\"") { return .expo }
        if packageJSON(in: directory).contains("\"react-native\"") { return .reactNative }
        switch (hasIOS(in: directory), hasAndroid(in: directory)) {
        case (true, true): return .native
        case (true, false): return .ios
        case (false, true): return .android
        case (false, false): throw MobileScaffoldError.noProject(directory: directory.path)
        }
    }

    /// The platform folders to scaffold. Flutter and React Native use their ios/ and android/ folders.
    static func platformsFor(_ framework: MobileFramework, in directory: URL) throws -> [String] {
        switch framework {
        case .ios: return ["ios"]
        case .android: return ["android"]
        case .expo: return []
        case .auto: return []
        case .native, .flutter, .reactNative:
            var platforms: [String] = []
            if hasIOS(in: directory) { platforms.append("ios") }
            if hasAndroid(in: directory) { platforms.append("android") }
            if platforms.isEmpty {
                throw MobileScaffoldError.noPlatformFolder(framework: framework, directory: directory.path)
            }
            return platforms
        }
    }

    /// A platform's fastlane folder lives in its own folder when that exists, else at the root.
    static func platformFolder(_ platform: String, in directory: URL) -> String {
        isDirectory(directory.appendingPathComponent(platform)) ? platform : "."
    }

    static func hasIOS(in directory: URL) -> Bool {
        if isDirectory(directory.appendingPathComponent("ios")) { return true }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
    }

    static func hasAndroid(in directory: URL) -> Bool {
        if isDirectory(directory.appendingPathComponent("android")) { return true }
        let fm = FileManager.default
        return fm.fileExists(atPath: directory.appendingPathComponent("settings.gradle").path)
            || fm.fileExists(atPath: directory.appendingPathComponent("settings.gradle.kts").path)
    }

    static func packageJSON(in directory: URL) -> String {
        (try? String(contentsOf: directory.appendingPathComponent("package.json"), encoding: .utf8)) ?? ""
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func report(_ framework: MobileFramework, _ platforms: [String], _ writer: Writer)
        -> MobileScaffoldReport
    {
        MobileScaffoldReport(framework: framework, platforms: platforms, lines: writer.lines, dryRun: writer.dryRun)
    }

    /// Recognises a Gemfile line that already installs fastlane (commented-out lines do not count).
    static let fastlaneGemLine = try! NSRegularExpression(pattern: #"^\s*gem\s*\(?\s*["']fastlane["']"#)
    /// Appended to an existing Gemfile that has no fastlane line (React Native ships one for CocoaPods).
    static let fastlaneGemAppendix =
        "\n# Added by kinhin mobile init: fastlane lanes live in ios/ and android/.\ngem \"fastlane\", \"~> 2.240\"\n"

    /// Runs the file operations, collecting the lines the CLI prints.
    struct Writer {
        let root: URL
        let force: Bool
        let dryRun: Bool
        private(set) var lines: [String] = []

        init(root: URL, force: Bool, dryRun: Bool) {
            self.root = root
            self.force = force
            self.dryRun = dryRun
        }

        mutating func note(_ text: String) {
            lines.append("  note    \(text)")
        }

        /// Writes a bundled template to `relativePath`, unless the file exists and `force` is off.
        mutating func write(template: String, to relativePath: String) throws {
            guard let text = MobileTemplates.files[template] else {
                throw MobileScaffoldError.cannotWrite(path: relativePath, reason: "no template named \(template)")
            }
            try write(text: text, to: relativePath)
        }

        mutating func write(text: String, to relativePath: String) throws {
            let destination = root.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: destination.path) && !force {
                lines.append("  keep    \(relativePath) (exists; use --force to overwrite)")
                return
            }
            if dryRun {
                lines.append("  would write \(relativePath)")
                return
            }
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try withNewline(text).write(to: destination, atomically: true, encoding: .utf8)
            } catch {
                throw MobileScaffoldError.cannotWrite(path: relativePath, reason: error.localizedDescription)
            }
            lines.append("  wrote   \(relativePath)")
        }

        /// The root Gemfile: created from the template when missing, otherwise fastlane is appended.
        mutating func gemfile() throws {
            let destination = root.appendingPathComponent("Gemfile")
            guard FileManager.default.fileExists(atPath: destination.path) else {
                try write(template: "Gemfile", to: "Gemfile")
                return
            }
            guard let existing = try? String(contentsOf: destination, encoding: .utf8) else {
                throw MobileScaffoldError.unreadableGemfile(path: destination.path)
            }
            if existing.split(separator: "\n", omittingEmptySubsequences: false).contains(where: isFastlaneGemLine) {
                lines.append("  keep    Gemfile (already has fastlane)")
                return
            }
            if dryRun {
                lines.append("  would append fastlane to Gemfile")
                return
            }
            do {
                let handle = try FileHandle(forWritingTo: destination)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(Self.appendix.utf8))
            } catch {
                throw MobileScaffoldError.cannotWrite(path: "Gemfile", reason: error.localizedDescription)
            }
            lines.append("  append  fastlane to Gemfile")
        }

        private static let appendix = MobileScaffold.fastlaneGemAppendix

        private func isFastlaneGemLine(_ line: Substring) -> Bool {
            let text = String(line)
            return MobileScaffold.fastlaneGemLine.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
                != nil
        }

        /// Fastfile, Appfile, and for iOS the Matchfile, under the platform's fastlane folder.
        mutating func scaffoldFastlane(platform: String, folder: String) throws {
            let base = folder == "." ? "fastlane" : "\(folder)/fastlane"
            try write(template: "\(platform)/fastlane/Fastfile", to: "\(base)/Fastfile")
            try write(template: "\(platform)/fastlane/Appfile", to: "\(base)/Appfile")
            if platform == "ios" {
                try write(template: "ios/fastlane/Matchfile", to: "\(base)/Matchfile")
            }
        }

        /// The CI workflow: the header, then one job per platform, with the framework's setup steps spliced in.
        mutating func workflow(framework: MobileFramework, platforms: [String], directory: URL) throws {
            var text = withNewline(try template("github/header.yml"))
            for platform in platforms {
                text += try job(platform: platform, framework: framework, directory: directory)
            }
            try write(text: text, to: ".github/workflows/mobile-release.yml")
        }

        /// A job template with `__PREBUILD__` replaced by the framework's setup steps and `__DIR__` by the folder.
        private func job(platform: String, framework: MobileFramework, directory: URL) throws -> String {
            let template = try self.template("github/\(platform).job.yml")
            let prebuild = try prebuildSteps(platform: platform, framework: framework)
            let folder = MobileScaffold.platformFolder(platform, in: directory)
            var out = ""
            for line in template.components(separatedBy: "\n") {
                if line == "__PREBUILD__" {
                    out += prebuild
                } else {
                    out += line.replacingOccurrences(of: "__DIR__", with: folder) + "\n"
                }
            }
            return out
        }

        private func prebuildSteps(platform: String, framework: MobileFramework) throws -> String {
            switch framework {
            case .flutter: return withNewline(try template("github/prebuild/flutter-\(platform).yml"))
            case .reactNative: return withNewline(try template("github/prebuild/react-native-\(platform).yml"))
            default: return ""
            }
        }

        private func template(_ name: String) throws -> String {
            guard let text = MobileTemplates.files[name] else {
                throw MobileScaffoldError.cannotWrite(path: name, reason: "no template named \(name)")
            }
            return text
        }
    }
}

/// Ensures a file's text ends in exactly one newline.
private func withNewline(_ text: String) -> String {
    text.hasSuffix("\n") ? text : text + "\n"
}
