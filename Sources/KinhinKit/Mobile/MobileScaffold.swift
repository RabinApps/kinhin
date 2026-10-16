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
    /// A web app wrapped by Capacitor (or Ionic) into ios/ and android/ folders that Capacitor generates.
    case capacitor
    /// A Kotlin Multiplatform project: a shared module, androidApp/ (Gradle) and iosApp/ (Xcode).
    case kmp
    /// A .NET MAUI app: one C# project (.csproj with UseMaui). fastlane signs nothing; dotnet publish builds the artifacts.
    case maui
}

/// What a scaffold run did, line by line, for the CLI to print.
public struct MobileScaffoldReport: Equatable, Sendable {
    public let framework: MobileFramework
    public let platforms: [String]
    public let lines: [String]
    public let dryRun: Bool
    /// The CI system the release pipeline was written for (nil for Expo, which gets none).
    public let ci: CISystem?
    /// The release pipeline file, relative to the repository root (nil for Expo).
    public let pipelinePath: String?
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
    /// `ci` nil = the system the repository uses (`CISystem.detect`).
    public static func run(
        in directory: URL, framework requested: MobileFramework, ci requestedCI: CISystem? = nil, force: Bool,
        dryRun: Bool
    ) throws -> MobileScaffoldReport {
        let framework = requested == .auto ? try detect(in: directory) : requested
        let platforms = try platformsFor(framework, in: directory)
        let repository = repositoryRoot(of: directory) ?? directory
        var writer = Writer(
            root: directory, appPath: repoRelativePath(of: directory), repositoryRoot: repository, force: force,
            dryRun: dryRun)

        if framework == .expo {
            try writer.write(template: "expo/eas.json", to: "eas.json")
            writer.note("Expo uses EAS Build/Submit by default; no fastlane workflow is written.")
            writer.note("For fastlane, run 'npx expo prebuild' and re-run with --framework react-native.")
            return report(framework, platforms, writer, ci: nil, pipeline: nil)
        }
        let ci = requestedCI ?? CISystem.detect(repositoryRoot: repository)

        try writer.gemfile()
        for platform in platforms {
            try writer.scaffoldFastlane(
                platform: platform, folder: fastlaneFolder(platform, framework: framework, in: directory),
                screenshots: framework != .maui, androidModule: framework == .kmp ? "" : "app")
        }
        let pipeline = try writer.pipeline(ci: ci, framework: framework, platforms: platforms, directory: directory)
        if platforms.contains("ios") {
            // Where the Xcode project lives: iosApp/ for Kotlin Multiplatform, ios/, or the root for a native project.
            noteLowIOSDeploymentTarget(
                in: directory, folder: fastlaneFolder("ios", framework: framework, in: directory), writer: &writer)
        }
        return report(framework, platforms, writer, ci: ci, pipeline: pipeline)
    }

    /// The framework a folder looks like, checked in order: Flutter, Expo, React Native, then the platform folders.
    public static func detect(in directory: URL) throws -> MobileFramework {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent("pubspec.yaml").path) { return .flutter }
        let package = packageJSON(in: directory)
        if package.contains("\"expo\"") { return .expo }
        if package.contains("\"@capacitor/core\"") { return .capacitor }
        if package.contains("\"react-native\"") { return .reactNative }
        if isMAUI(in: directory) { return .maui }
        if isKotlinMultiplatform(in: directory) { return .kmp }
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
        case .kmp, .maui: return ["ios", "android"]
        case .native, .flutter, .reactNative, .capacitor:
            var platforms: [String] = []
            if hasIOS(in: directory) { platforms.append("ios") }
            if hasAndroid(in: directory) { platforms.append("android") }
            if platforms.isEmpty {
                throw MobileScaffoldError.noPlatformFolder(framework: framework, directory: directory.path)
            }
            return platforms
        }
    }

    /// The project folder relative to the git repository that contains it: "." for a project at the root, and
    /// "apps/mobile" for a monorepo app. With no repository above it, "." is the only sensible answer.
    static func repoRelativePath(of directory: URL) -> String {
        guard let root = repositoryRoot(of: directory) else { return "." }
        let base = root.pathComponents
        let full = directory.standardizedFileURL.pathComponents
        let relative = full.dropFirst(base.count)
        return relative.isEmpty ? "." : relative.joined(separator: "/")
    }

    /// The nearest folder at or above `directory` that holds `.git`, or nil when there is none.
    static func repositoryRoot(of directory: URL) -> URL? {
        let fm = FileManager.default
        var root = directory.standardizedFileURL
        while !fm.fileExists(atPath: root.appendingPathComponent(".git").path) {
            // Stop at "/" by depth: deletingLastPathComponent() on the root does not return an equal path.
            if root.pathComponents.count <= 1 { return nil }
            root = root.deletingLastPathComponent()
        }
        return root
    }

    /// Joins two relative paths, where "." is the empty path.
    static func joinPath(_ base: String, _ child: String) -> String {
        if base == "." { return child }
        if child == "." { return base }
        return "\(base)/\(child)"
    }

    /// A platform's fastlane folder lives in its own folder when that exists, else at the root. Kotlin Multiplatform
    /// keeps its native projects in iosApp/ and androidApp/. MAUI has no native folders, so its fastlane sits in ios/ and android/.
    static func fastlaneFolder(_ platform: String, framework: MobileFramework, in directory: URL) -> String {
        switch framework {
        case .kmp: return platform == "ios" ? "iosApp" : "androidApp"
        case .maui: return platform
        default: return platformFolder(platform, in: directory)
        }
    }

    static func platformFolder(_ platform: String, in directory: URL) -> String {
        isDirectory(directory.appendingPathComponent(platform)) ? platform : "."
    }

    /// A .NET MAUI project: a .csproj with UseMaui, at the root or one folder down.
    static func isMAUI(in directory: URL) -> Bool {
        mauiProjectPath(
            list: { folder in
                let url = folder.isEmpty ? directory : directory.appendingPathComponent(folder)
                // detection probe: an unreadable folder just has no MAUI project in it
                return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            },
            // detection probe: an unreadable project file is not a MAUI project
            read: { path in try? String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8) }
        ) != nil
    }

    /// The relative path of the first .csproj that sets UseMaui, at the root or one folder down. Hidden folders and
    /// dependency or build output folders are skipped, so a copy inside node_modules does not count. `list` and `read`
    /// let the scaffold (files on disk) and the runner probe (a ProjectFileReading) share this one search.
    static func mauiProjectPath(
        list: (String) throws -> [String], read: (String) throws -> String?
    ) rethrows -> String? {
        let skipped: Set<String> = ["node_modules", "Pods", "build", "bin", "obj", "DerivedData"]
        let root = try list("")
        let folders = [""] + root.filter { !$0.hasPrefix(".") && !skipped.contains($0) }
        for folder in folders {
            let names = folder.isEmpty ? root : try list(folder)
            for name in names where name.hasSuffix(".csproj") {
                let path = folder.isEmpty ? name : "\(folder)/\(name)"
                if try read(path)?.contains("<UseMaui>true</UseMaui>") == true { return path }
            }
        }
        return nil
    }

    /// A Kotlin Multiplatform project: an iosApp/ folder, Gradle settings, and a build file that applies the
    /// multiplatform plugin (the root or the shared module).
    static func isKotlinMultiplatform(in directory: URL) -> Bool {
        let fm = FileManager.default
        guard isDirectory(directory.appendingPathComponent("iosApp")),
            fm.fileExists(atPath: directory.appendingPathComponent("settings.gradle.kts").path)
                || fm.fileExists(atPath: directory.appendingPathComponent("settings.gradle").path)
        else { return false }
        let builds = ["build.gradle.kts", "build.gradle", "shared/build.gradle.kts", "shared/build.gradle"]
        return builds.contains { name in
            // detection probe: a missing or unreadable build file is not Kotlin Multiplatform
            ((try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? "")
                .contains("multiplatform")
        }
    }

    static func hasIOS(in directory: URL) -> Bool {
        if isDirectory(directory.appendingPathComponent("ios")) { return true }
        // detection probe: an unreadable folder has no Xcode project in it
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
        // detection probe: no readable package.json reads as empty
        (try? String(contentsOf: directory.appendingPathComponent("package.json"), encoding: .utf8)) ?? ""
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func report(
        _ framework: MobileFramework, _ platforms: [String], _ writer: Writer, ci: CISystem?, pipeline: String?
    ) -> MobileScaffoldReport {
        MobileScaffoldReport(
            framework: framework, platforms: platforms, lines: writer.lines, dryRun: writer.dryRun, ci: ci,
            pipelinePath: pipeline)
    }

    /// Where each system's release pipeline goes, relative to the repository root. GitLab's is included from
    /// .gitlab-ci.yml, and Bitbucket's main file is never overwritten (see `Writer.pipeline`).
    static func pipelinePath(_ ci: CISystem) -> String {
        switch ci {
        case .github: return ".github/workflows/mobile-release.yml"
        case .gitea: return ".gitea/workflows/mobile-release.yml"
        case .forgejo: return ".forgejo/workflows/mobile-release.yml"
        case .gitlab: return ".gitlab/mobile-release.yml"
        case .bitbucket: return "bitbucket-pipelines.yml"
        case .azure: return ".azure-pipelines/mobile-release.yml"
        case .buildkite: return ".buildkite/mobile-release.yml"
        }
    }

    /// The release steps script the non-GitHub pipelines call, relative to the app folder.
    static let releaseScriptPath = ".kinhin/mobile-release.sh"

    /// The lowest iOS deployment target the Xcode 26 toolchain accepts. `flutter create` still writes 13.0.
    static let minimumIOSDeploymentTarget = 15.0

    /// Notes the first iOS deployment target below the minimum, so the release build does not fail for a reason the
    /// user can see. The project file is not edited: the target is the user's choice to change.
    static func noteLowIOSDeploymentTarget(in directory: URL, folder: String, writer: inout Writer) {
        let project = folder == "." ? directory : directory.appendingPathComponent(folder)
        guard let enumerator = FileManager.default.enumerator(at: project, includingPropertiesForKeys: nil) else {
            return
        }
        // Generated or third-party projects (CocoaPods' Pods.xcodeproj pins old targets per pod) are not the user's to fix.
        let skipped: Set<String> = ["Pods", "node_modules", "build", "DerivedData", ".git", ".symlinks"]
        var projectFiles: [URL] = []
        for case let url as URL in enumerator {
            if skipped.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
            } else if url.lastPathComponent == "project.pbxproj" {
                projectFiles.append(url)
            }
        }
        let pattern = deploymentTargetPattern
        for url in projectFiles.sorted(by: { $0.path < $1.path }) {
            // advisory scan only: an unreadable project file is skipped, not a scaffold failure
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let valueRange = Range(match.range(at: 1), in: text), let value = Double(text[valueRange]),
                    value < minimumIOSDeploymentTarget
                else { continue }
                // Both sides resolved, so /var and /private/var (which the enumerator returns) compare equal.
                let base = project.resolvingSymlinksInPath().path
                let suffix = url.resolvingSymlinksInPath().path.dropFirst(base.count + 1)
                let relative = joinPath(folder, String(suffix))
                writer.note(
                    "iOS deployment target is \(text[valueRange]) in \(relative); Xcode 26 needs "
                        + "\(minimumIOSDeploymentTarget) or higher. Set IPHONEOS_DEPLOYMENT_TARGET to 15.0 there.")
                return
            }
        }
    }

    /// Recognises a Gemfile line that already installs fastlane (commented-out lines do not count).
    static let fastlaneGemLine = constantRegex(#"^\s*gem\s*\(?\s*["']fastlane["']"#)
    /// Captures the value of an Xcode project's `IPHONEOS_DEPLOYMENT_TARGET` setting.
    static let deploymentTargetPattern = constantRegex(#"IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);"#)

    /// Compiles a pattern written in this file. The patterns are constants; a failure to compile is a programmer error.
    private static func constantRegex(_ pattern: String) -> NSRegularExpression {
        // The error is not dropped: a failure traps in the preconditionFailure below.
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("invalid constant pattern: \(pattern)")
        }
        return regex
    }
    /// Appended to an existing Gemfile that has no fastlane line (React Native ships one for CocoaPods).
    static let fastlaneGemAppendix =
        "\n# Added by kinhin mobile init: fastlane lanes live in ios/ and android/.\ngem \"fastlane\", \"~> 2.240\"\n"

    /// Runs the file operations, collecting the lines the CLI prints.
    struct Writer {
        let root: URL
        let force: Bool
        let dryRun: Bool
        private(set) var lines: [String] = []

        /// The project folder relative to the git repository root (".", or "apps/mobile" in a monorepo).
        let appPath: String
        /// The git repository root (the project folder when there is no repository): GitHub reads workflows only from
        /// its `.github/workflows/`.
        let repositoryRoot: URL

        init(root: URL, appPath: String, repositoryRoot: URL, force: Bool, dryRun: Bool) {
            self.root = root
            self.appPath = appPath
            self.repositoryRoot = repositoryRoot
            self.force = force
            self.dryRun = dryRun
        }

        /// The repository root as seen from the project folder: "." or "../.." for "apps/mobile".
        var upToRepository: String {
            appPath == "." ? "." : appPath.split(separator: "/").map { _ in ".." }.joined(separator: "/")
        }

        mutating func note(_ text: String) {
            lines.append("  note    \(text)")
        }

        /// Writes a template only when the file is absent, even with `force`: for files the app already owns (a Flutter
        /// debug manifest carries permissions the app needs). The note tells the user what to merge by hand.
        mutating func writeIfAbsent(template: String, to relativePath: String, note: String) throws {
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path) else {
                try write(template: template, to: relativePath)
                return
            }
            lines.append("  keep    \(relativePath) (exists and is not overwritten: \(note))")
        }

        /// Writes a bundled template to `relativePath`, unless the file exists and `force` is off.
        mutating func write(template: String, to relativePath: String) throws {
            guard let text = MobileTemplates.files[template] else {
                throw MobileScaffoldError.cannotWrite(path: relativePath, reason: "no template named \(template)")
            }
            try write(text: text, to: relativePath)
        }

        /// Writes `text` to `relativePath` under `base` (the project folder unless given), unless the file exists and
        /// `force` is off. Lines name the path from the project folder, or from the repository root for a file there.
        mutating func write(text: String, to path: String, under base: URL? = nil) throws {
            let base = base ?? root
            let destination = base.appendingPathComponent(path)
            let relativePath = base == root ? path : MobileScaffold.joinPath(upToRepository, path)
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
            // the else branch turns an unreadable Gemfile into MobileScaffoldError.unreadableGemfile
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
                // closing after a completed write; a close failure loses nothing
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
        /// `androidModule` is the Gradle module folder under the platform folder ("" when the platform folder is the module).
        mutating func scaffoldFastlane(
            platform: String, folder: String, screenshots: Bool, androidModule: String = "app"
        )
            throws
        {
            let base = folder == "." ? "fastlane" : "\(folder)/fastlane"
            try write(template: "\(platform)/fastlane/Fastfile", to: "\(base)/Fastfile")
            try write(template: "\(platform)/fastlane/Appfile", to: "\(base)/Appfile")
            if platform == "ios" {
                try write(template: "ios/fastlane/Matchfile", to: "\(base)/Matchfile")
            }
            if screenshots {
                try scaffoldScreenshots(platform: platform, folder: folder, base: base, androidModule: androidModule)
            }
        }

        /// Screenshot settings and the sample UI or instrumented test. The Xcode UI test target and the Gradle
        /// test dependencies are not written: they live in the project file, so docs/mobile-screenshots.md
        /// describes those steps.
        mutating func scaffoldScreenshots(platform: String, folder: String, base: String, androidModule: String) throws
        {
            switch platform {
            case "ios":
                try write(template: "ios/fastlane/Snapfile", to: "\(base)/Snapfile")
                try write(template: "ios/fastlane/Framefile.json", to: "\(base)/Framefile.json")
                try write(
                    template: "ios/UITests/SnapshotHelper.swift",
                    to: MobileScaffold.joinPath(folder, "UITests/SnapshotHelper.swift"))
                try write(
                    template: "ios/UITests/ScreenshotTests.swift",
                    to: MobileScaffold.joinPath(folder, "UITests/ScreenshotTests.swift"))
            case "android":
                try write(template: "android/fastlane/Screengrabfile", to: "\(base)/Screengrabfile")
                let module = androidModule.isEmpty ? folder : MobileScaffold.joinPath(folder, androidModule)
                try write(
                    template: "android/app/src/androidTest/java/screenshots/ScreenshotTest.java",
                    to: MobileScaffold.joinPath(module, "src/androidTest/java/screenshots/ScreenshotTest.java"))
                try writeIfAbsent(
                    template: "android/app/src/debug/AndroidManifest.xml",
                    to: MobileScaffold.joinPath(module, "src/debug/AndroidManifest.xml"),
                    note: "add the Screengrab permissions listed in that template to the existing debug manifest")
            default:
                break
            }
        }

        /// The release pipeline for `ci`; returns its path from the repository root. GitHub's workflow carries the setup
        /// steps itself (setup actions). Every other system calls one script, `.kinhin/mobile-release.sh`, which holds those
        /// steps as shell, so its pipeline file only triggers, targets the runner, passes secrets and keeps screenshots.
        mutating func pipeline(ci: CISystem, framework: MobileFramework, platforms: [String], directory: URL) throws
            -> String
        {
            guard ci != .github else {
                var text = withNewline(try template("ci/github/header.yml"))
                for platform in platforms {
                    text += try job(platform: platform, framework: framework, directory: directory)
                }
                let path = MobileScaffold.pipelinePath(.github)
                try write(text: text, to: path, under: repositoryRoot)
                return path
            }

            func folder(_ platform: String) -> String {
                MobileScaffold.fastlaneFolder(platform, framework: framework, in: directory)
            }
            let scriptValues = [
                "__FRAMEWORK__": framework.rawValue, "__IOS_DIR__": folder("ios"),
                "__ANDROID_DIR__": folder("android"),
            ]
            try write(text: try fill("ci/mobile-release.sh", scriptValues), to: MobileScaffold.releaseScriptPath)

            var path = MobileScaffold.pipelinePath(ci)
            // The main Bitbucket file holds every pipeline of the repository: never replace one that exists.
            let existing = repositoryRoot.appendingPathComponent(path).path
            if ci == .bitbucket, FileManager.default.fileExists(atPath: existing) {
                path = "bitbucket-pipelines.mobile-release.yml"
                note(
                    "bitbucket-pipelines.yml exists and is not changed: copy the mobile-release entry from \(path) "
                        + "under its pipelines: custom: section.")
            }
            // Gitea and Forgejo run the same workflow syntax.
            let system = ci == .forgejo ? "gitea" : ci.rawValue
            let values = [
                "__WORKFLOW_PATH__": path,
                "__SCRIPT__": MobileScaffold.joinPath(appPath, MobileScaffold.releaseScriptPath),
                "__IOS_SCREENSHOTS__": MobileScaffold.joinPath(
                    appPath, MobileScaffold.joinPath(folder("ios"), "fastlane/screenshots")),
                "__ANDROID_SCREENSHOTS__": MobileScaffold.joinPath(
                    appPath, MobileScaffold.joinPath(folder("android"), "fastlane/metadata/android")),
            ]
            var text = withNewline(try fill("ci/\(system)/header.yml", values))
            for platform in platforms {
                text += withNewline(try fill("ci/\(system)/\(platform).job.yml", values))
            }
            try write(text: text, to: path, under: repositoryRoot)

            switch ci {
            case .gitlab: try gitlabInclude(path)
            case .azure:
                note("Create a pipeline from \(path): Pipelines > New pipeline > Existing Azure Pipelines YAML file.")
            case .buildkite:
                note("Make a Buildkite pipeline whose steps are: buildkite-agent pipeline upload \(path)")
            default: break
            }
            return path
        }

        /// GitLab runs only .gitlab-ci.yml, so the release jobs are included from it: a new one is written when there is
        /// none, and an existing one is never edited (the note says what to add).
        private mutating func gitlabInclude(_ path: String) throws {
            let main = repositoryRoot.appendingPathComponent(".gitlab-ci.yml")
            guard FileManager.default.fileExists(atPath: main.path) else {
                let include =
                    "# Written by kinhin mobile init: the manual mobile release jobs.\n"
                    + "include:\n  - local: \(path)\n"
                try write(text: include, to: ".gitlab-ci.yml", under: repositoryRoot)
                return
            }
            // an unreadable .gitlab-ci.yml is treated as not yet including the path, so the include is added
            if (try? String(contentsOf: main, encoding: .utf8))?.contains(path) == true {
                lines.append("  keep    .gitlab-ci.yml (already includes \(path))")
            } else {
                note("Add this to .gitlab-ci.yml so the release jobs run: include: [{ local: \(path) }]")
            }
        }

        /// A template with each placeholder replaced.
        private func fill(_ name: String, _ values: [String: String]) throws -> String {
            var text = try template(name)
            for (placeholder, value) in values { text = text.replacingOccurrences(of: placeholder, with: value) }
            return text
        }

        /// A job template with `__PREBUILD__` replaced by the framework's setup steps and `__DIR__` by the folder.
        private func job(platform: String, framework: MobileFramework, directory: URL) throws -> String {
            let template = try self.template("ci/github/\(platform).job.yml")
            let prebuild = try prebuildSteps(platform: platform, framework: framework)
            let folder = MobileScaffold.joinPath(
                appPath, MobileScaffold.fastlaneFolder(platform, framework: framework, in: directory))
            // Capacitor 8's Android library compiles with Java 21; the other frameworks run on Java 17.
            let javaVersion = framework == .capacitor ? "21" : "17"
            var out = ""
            for line in template.components(separatedBy: "\n") {
                if line == "__PREBUILD__" {
                    out += prebuild
                } else {
                    out +=
                        line.replacingOccurrences(of: "__DIR__", with: folder)
                        .replacingOccurrences(of: "__JAVA_VERSION__", with: javaVersion) + "\n"
                }
            }
            return out
        }

        private func prebuildSteps(platform: String, framework: MobileFramework) throws -> String {
            switch framework {
            case .flutter: return withNewline(try steps("ci/github/prebuild/flutter-\(platform).yml"))
            case .reactNative: return withNewline(try steps("ci/github/prebuild/react-native-\(platform).yml"))
            case .capacitor: return withNewline(try steps("ci/github/prebuild/capacitor-\(platform).yml"))
            case .kmp: return withNewline(try steps("ci/github/prebuild/kmp-\(platform).yml"))
            case .maui: return withNewline(try steps("ci/github/prebuild/maui-\(platform).yml"))
            default: return ""
            }
        }

        /// A setup-steps template with its `__APP__` placeholder set to the project's path.
        private func steps(_ name: String) throws -> String {
            try template(name).replacingOccurrences(of: "__APP__", with: appPath)
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
