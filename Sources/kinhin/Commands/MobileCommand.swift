import Foundation
import KinhinKit

/// `kinhin mobile init [DIR] [--framework NAME] [--force] [--dry-run]`: scaffolds fastlane lanes and the CI release
/// workflow into an iOS, Android, Flutter, React Native or Expo project. Files that already exist are kept unless
/// `--force` is given, so running it again is safe.
enum MobileCommand {
    /// `args` are the arguments after `mobile init`.
    static func run(_ args: [String]) {
        let frameworkName = flag("--framework", in: args) ?? MobileFramework.auto.rawValue
        guard let framework = MobileFramework(rawValue: frameworkName) else {
            fail(
                "unknown framework '\(frameworkName)' (auto, ios, android, native, flutter, react-native, expo)",
                exit: .usage)
        }

        let directory = URL(fileURLWithPath: positionals(in: args).first ?? ".").standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            fail("no such directory: \(directory.path)", exit: .usage)
        }

        let dryRun = hasFlag("--dry-run", in: args)
        do {
            let report = try MobileScaffold.run(
                in: directory, framework: framework, force: hasFlag("--force", in: args), dryRun: dryRun)
            let platforms = report.platforms.isEmpty ? "none" : report.platforms.joined(separator: " ")
            print("mobile init: framework=\(report.framework.rawValue) platforms=\(platforms) dir=\(directory.path)")
            if dryRun { print("mobile init: dry run, nothing will be written") }
            report.lines.forEach { print($0) }
            if dryRun {
                print("mobile init: dry run complete. Nothing was written.")
            } else {
                print("mobile init: done. Add the secrets listed in .github/workflows/mobile-release.yml, then run")
                print("             'bundle install' and 'bundle exec fastlane lanes' from each platform folder.")
            }
        } catch let error as MobileScaffoldError {
            fail(error.localizedDescription, exit: exitCode(for: error))
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Arguments that are not flags or the value of `--framework`.
    private static func positionals(in args: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--framework" {
                index += 2
                continue
            }
            if !arg.hasPrefix("--") { result.append(arg) }
            index += 1
        }
        return result
    }

    /// A folder that is not a mobile project is a usage problem; anything else is a general failure.
    private static func exitCode(for error: MobileScaffoldError) -> CLIExit {
        switch error {
        case .noProject, .noPlatformFolder: return .usage
        case .unreadableGemfile, .cannotWrite: return .general
        }
    }
}
