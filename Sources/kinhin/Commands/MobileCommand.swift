import Foundation
import KinhinKit

/// `kinhin mobile init [DIR] [--framework NAME] [--force] [--dry-run]`: scaffolds fastlane lanes and the CI release workflow
/// into an iOS, Android, Flutter, React Native or Expo project. Files that already exist are kept unless `--force` is given,
/// so running it again is safe.
enum MobileCommand {
    /// What the arguments ask for, before anything touches the disk.
    struct Request: Equatable {
        var framework: MobileFramework
        var directory: String
        var force: Bool
        var dryRun: Bool
    }

    /// An argument problem, reported with exit code 2.
    struct UsageError: Error, Equatable {
        var message: String
    }

    /// `args` are the arguments after `mobile init`.
    static func run(_ args: [String]) {
        let request: Request
        do {
            request = try parse(args)
        } catch let error as UsageError {
            fail(error.message, exit: .usage)
        } catch {
            fail(error.localizedDescription, exit: .usage)
        }

        let directory = URL(fileURLWithPath: request.directory).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            fail("no such directory: \(directory.path)", exit: .usage)
        }

        do {
            let report = try MobileScaffold.run(
                in: directory, framework: request.framework, force: request.force, dryRun: request.dryRun)
            let platforms = report.platforms.isEmpty ? "none" : report.platforms.joined(separator: " ")
            print("mobile init: framework=\(report.framework.rawValue) platforms=\(platforms) dir=\(directory.path)")
            if request.dryRun { print("mobile init: dry run, nothing will be written") }
            report.lines.forEach { print($0) }
            if request.dryRun {
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

    /// Reads the arguments. The value after `--framework` is not a directory, so it is skipped when looking for DIR.
    static func parse(_ args: [String]) throws -> Request {
        let frameworkName = flag("--framework", in: args) ?? MobileFramework.auto.rawValue
        guard let framework = MobileFramework(rawValue: frameworkName) else {
            throw UsageError(
                message:
                    "unknown framework '\(frameworkName)' (auto, ios, android, native, flutter, react-native, expo, capacitor, kmp, maui)"
            )
        }
        return Request(
            framework: framework,
            directory: positionals(in: args).first ?? ".",
            force: hasFlag("--force", in: args),
            dryRun: hasFlag("--dry-run", in: args))
    }

    /// Arguments that are not flags or the value of `--framework`.
    static func positionals(in args: [String]) -> [String] {
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
    static func exitCode(for error: MobileScaffoldError) -> CLIExit {
        switch error {
        case .noProject, .noPlatformFolder: return .usage
        case .unreadableGemfile, .cannotWrite: return .general
        }
    }
}
