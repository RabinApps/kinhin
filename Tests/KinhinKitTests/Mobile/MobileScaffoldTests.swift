import Foundation
import XCTest

@testable import KinhinKit

final class MobileScaffoldTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    // MARK: - Fixtures

    private func folder(_ name: String, _ files: [String: String] = [:], dirs: [String] = []) throws -> URL {
        let url = work.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for dir in dirs {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for (path, text) in files {
            let target = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: target, atomically: true, encoding: .utf8)
        }
        return url
    }

    private func flutter(_ name: String = "flutter") throws -> URL {
        try folder(name, ["pubspec.yaml": "name: app\n"], dirs: ["ios", "android"])
    }

    private func reactNative(_ name: String = "rn") throws -> URL {
        try folder(
            name, ["package.json": "{\"dependencies\":{\"react-native\":\"0.80.0\"}}\n"], dirs: ["ios", "android"])
    }

    private func text(_ url: URL, _ path: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    private func exists(_ url: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path)
    }

    private func scaffold(
        _ url: URL, _ framework: MobileFramework = .auto, force: Bool = false, dryRun: Bool = false
    ) throws -> MobileScaffoldReport {
        try MobileScaffold.run(in: url, framework: framework, force: force, dryRun: dryRun)
    }

    private func assertThrows(
        _ expected: MobileScaffoldError, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? MobileScaffoldError, expected, file: file, line: line)
        }
    }

    // MARK: - Detection

    func testDetectsEachProjectShape() throws {
        XCTAssertEqual(try MobileScaffold.detect(in: try flutter()), .flutter)
        XCTAssertEqual(try MobileScaffold.detect(in: try reactNative()), .reactNative)
        XCTAssertEqual(
            try MobileScaffold.detect(
                in: try folder("expo", ["package.json": "{\"dependencies\":{\"expo\":\"~54\"}}"])),
            .expo)
        XCTAssertEqual(try MobileScaffold.detect(in: try folder("native", dirs: ["ios", "android"])), .native)
        XCTAssertEqual(try MobileScaffold.detect(in: try folder("ios-root", dirs: ["App.xcodeproj"])), .ios)
        XCTAssertEqual(
            try MobileScaffold.detect(in: try folder("android-root", ["settings.gradle.kts": ""])), .android)
    }

    func testEmptyFolderIsNotAProject() throws {
        let empty = try folder("empty")
        assertThrows(.noProject(directory: empty.path)) { _ = try MobileScaffold.detect(in: empty) }
    }

    func testReactNativeInDevDependenciesIsDetected() throws {
        let dir = try folder(
            "rn-dev", ["package.json": "{\"devDependencies\":{\"react-native\":\"0.80.0\"}}"], dirs: ["ios"])
        XCTAssertEqual(try MobileScaffold.detect(in: dir), .reactNative)
    }

    // MARK: - Scaffolding

    func testFlutterGetsFastlaneInBothFoldersAndAWorkflow() throws {
        let dir = try flutter()
        let report = try scaffold(dir)
        XCTAssertEqual(report.framework, .flutter)
        XCTAssertEqual(report.platforms, ["ios", "android"])
        XCTAssertTrue(exists(dir, "Gemfile"))
        XCTAssertTrue(exists(dir, "ios/fastlane/Fastfile"))
        XCTAssertTrue(exists(dir, "ios/fastlane/Matchfile"))
        XCTAssertTrue(exists(dir, "android/fastlane/Fastfile"))
        let workflow = try text(dir, ".github/workflows/mobile-release.yml")
        XCTAssertTrue(workflow.contains("\n  ios:\n"))
        XCTAssertTrue(workflow.contains("\n  android:\n"))
        XCTAssertTrue(workflow.contains("ruby/setup-ruby@"))
        XCTAssertFalse(workflow.contains("__DIR__"))
        XCTAssertFalse(workflow.contains("__PREBUILD__"))
    }

    func testFlutterSetsUpSdkBeforeCocoaPodsAndBuildsTheIOSConfig() throws {
        let dir = try flutter()
        _ = try scaffold(dir)
        let workflow = try text(dir, ".github/workflows/mobile-release.yml")
        let sdk = try XCTUnwrap(workflow.range(of: "subosito/flutter-action@"))
        let pods = try XCTUnwrap(workflow.range(of: "Install CocoaPods"))
        XCTAssertLessThan(sdk.lowerBound, pods.lowerBound, "the Flutter SDK must be installed before pod install runs")
        XCTAssertTrue(workflow.contains("flutter build ios --config-only --release"))
        XCTAssertTrue(workflow.contains("flutter pub get"))
    }

    func testReactNativeInstallsNodeDependenciesBeforeCocoaPods() throws {
        let dir = try reactNative()
        _ = try scaffold(dir)
        let workflow = try text(dir, ".github/workflows/mobile-release.yml")
        let npm = try XCTUnwrap(workflow.range(of: "npm install"))
        let pods = try XCTUnwrap(workflow.range(of: "Install CocoaPods"))
        XCTAssertLessThan(npm.lowerBound, pods.lowerBound)
        XCTAssertTrue(workflow.contains("actions/setup-node@"))
    }

    func testMonorepoAppGetsWorkflowPathsFromTheRepositoryRoot() throws {
        let repo = try folder("monorepo", dirs: [".git"])
        let app = try folder("monorepo/apps/mobile", ["pubspec.yaml": "name: app\n"], dirs: ["ios", "android"])
        _ = try scaffold(app)
        let workflow = try text(app, ".github/workflows/mobile-release.yml")
        XCTAssertTrue(workflow.contains("working-directory: apps/mobile/ios"), workflow)
        XCTAssertTrue(workflow.contains("working-directory: apps/mobile/android"), workflow)
        XCTAssertTrue(workflow.contains("working-directory: apps/mobile\n"), "setup steps run at the app folder")
        XCTAssertFalse(workflow.contains("__APP__"))
        XCTAssertEqual(MobileScaffold.repoRelativePath(of: repo), ".")
    }

    func testProjectOutsideAnyRepositoryUsesTheProjectRoot() throws {
        let dir = try flutter()
        XCTAssertEqual(MobileScaffold.repoRelativePath(of: dir), ".")
        _ = try scaffold(dir)
        XCTAssertTrue(try text(dir, ".github/workflows/mobile-release.yml").contains("working-directory: ios"))
    }

    func testReactNativeInstallsWithPnpmWhenThatIsTheLockfile() throws {
        let dir = try reactNative()
        _ = try scaffold(dir)
        let workflow = try text(dir, ".github/workflows/mobile-release.yml")
        XCTAssertTrue(workflow.contains("pnpm install --frozen-lockfile"))
        XCTAssertTrue(workflow.contains("yarn install --frozen-lockfile"))
    }

    func testLowIOSDeploymentTargetIsNotedWithTheFix() throws {
        let dir = try flutter()
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("ios/Runner.xcodeproj"), withIntermediateDirectories: true)
        try "\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 13.0;\n".write(
            to: dir.appendingPathComponent("ios/Runner.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        let report = try scaffold(dir)
        XCTAssertTrue(
            report.lines.contains {
                $0.contains("iOS deployment target is 13.0") && $0.contains("Set IPHONEOS_DEPLOYMENT_TARGET to 15.0")
            },
            report.lines.joined(separator: "\n"))
        XCTAssertTrue(
            try text(dir, "ios/Runner.xcodeproj/project.pbxproj").contains("= 13.0;"), "the project is not edited")
    }

    func testCurrentIOSDeploymentTargetIsNotNoted() throws {
        let dir = try flutter()
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("ios/Runner.xcodeproj"), withIntermediateDirectories: true)
        try "IPHONEOS_DEPLOYMENT_TARGET = 15.0;\n".write(
            to: dir.appendingPathComponent("ios/Runner.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        let report = try scaffold(dir)
        XCTAssertFalse(report.lines.contains { $0.contains("deployment target") })
    }

    /// Every action a generated workflow uses is pinned to a 40-character commit SHA, with the release in a comment,
    /// the same policy as ci.yml. Dependabot updates the pins.
    func testEveryGeneratedActionIsPinnedToACommitSHA() throws {
        let pinned = try NSRegularExpression(
            pattern: #"uses: [^@\s]+@[0-9a-f]{40} # v\S+$"#, options: [.anchorsMatchLines])
        let frameworks: [(String, MobileFramework)] = [
            ("flutter", .flutter), ("rn", .reactNative), ("native", .native),
        ]
        for (name, framework) in frameworks {
            let dir = try folder(
                "pins-\(name)",
                ["pubspec.yaml": "name: x\n", "package.json": "{\"dependencies\":{\"react-native\":\"0\"}}"],
                dirs: ["ios", "android"])
            _ = try scaffold(dir, framework)
            let workflow = try text(dir, ".github/workflows/mobile-release.yml")
            let uses = workflow.components(separatedBy: "\n").filter { $0.contains("uses:") }
            XCTAssertFalse(uses.isEmpty, name)
            for line in uses {
                XCTAssertNotNil(
                    pinned.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                    "\(name): unpinned action: \(line)")
            }
        }
    }

    func testScreenshotFilesAreScaffoldedForIOSAndAndroid() throws {
        let dir = try folder("shots", dirs: ["ios", "android"])
        _ = try scaffold(dir, .native)
        XCTAssertTrue(exists(dir, "ios/fastlane/Snapfile"))
        XCTAssertTrue(exists(dir, "ios/fastlane/Framefile.json"))
        XCTAssertTrue(exists(dir, "ios/UITests/SnapshotHelper.swift"))
        XCTAssertTrue(exists(dir, "ios/UITests/ScreenshotTests.swift"))
        XCTAssertTrue(exists(dir, "android/fastlane/Screengrabfile"))
        XCTAssertTrue(exists(dir, "android/app/src/androidTest/java/screenshots/ScreenshotTest.java"))
        XCTAssertTrue(exists(dir, "android/app/src/debug/AndroidManifest.xml"))
        XCTAssertTrue(try text(dir, "ios/fastlane/Fastfile").contains("lane :screenshots do"))
        XCTAssertTrue(try text(dir, "android/fastlane/Fastfile").contains("lane :screenshots do"))
    }

    func testRootAndroidProjectPlacesTheTestUnderAppWithoutAFolderPrefix() throws {
        let dir = try folder("android-root-shots", ["settings.gradle.kts": ""], dirs: ["app"])
        _ = try scaffold(dir)
        XCTAssertTrue(exists(dir, "app/src/androidTest/java/screenshots/ScreenshotTest.java"))
        XCTAssertTrue(exists(dir, "fastlane/Screengrabfile"))
    }

    /// Flutter ships its own debug manifest with INTERNET, which the app needs. The scaffold must never overwrite it,
    /// even with --force.
    func testAnExistingDebugManifestIsNeverOverwritten() throws {
        let dir = try flutter("flutter-manifest")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("android/app/src/debug"), withIntermediateDirectories: true)
        try "<manifest><uses-permission android:name=\"android.permission.INTERNET\"/></manifest>\n".write(
            to: dir.appendingPathComponent("android/app/src/debug/AndroidManifest.xml"), atomically: true,
            encoding: .utf8)
        let report = try scaffold(dir, force: true)
        XCTAssertTrue(try text(dir, "android/app/src/debug/AndroidManifest.xml").contains("INTERNET"))
        XCTAssertTrue(
            report.lines.contains {
                $0.contains("android/app/src/debug/AndroidManifest.xml (exists and is not overwritten")
            })
    }

    /// The release workflow offers the screenshots lane, and the Android job does not run for the release choice.
    func testWorkflowOffersTheScreenshotsLaneAndSkipsAndroidForRelease() throws {
        let dir = try flutter("lanes")
        _ = try scaffold(dir)
        let workflow = try text(dir, ".github/workflows/mobile-release.yml")
        XCTAssertTrue(workflow.contains("options: [beta, release, screenshots]"))
        XCTAssertTrue(workflow.contains("if: inputs.lane != 'release'"))
    }

    /// The screenshots are kept as a CI artifact: uploaded for the screenshots lane even when it fails, from the
    /// platform folder (the path is relative to the workspace, so the folder is part of it).
    func testScreenshotArtifactIsUploadedForTheScreenshotsLaneOnly() throws {
        let dir = try folder("artifacts", dirs: ["ios", "android"])
        _ = try scaffold(dir, .native)
        let workflow = try text(dir, ".github/workflows/mobile-release.yml")
        XCTAssertTrue(workflow.contains("name: ios-screenshots"))
        XCTAssertTrue(workflow.contains("path: ios/fastlane/screenshots"))
        XCTAssertTrue(workflow.contains("name: android-screenshots"))
        XCTAssertTrue(workflow.contains("path: android/fastlane/metadata/android"))
        XCTAssertEqual(
            workflow.components(separatedBy: "if: ${{ always() && inputs.lane == 'screenshots' }}").count - 1, 2)
    }

    func testNativeProjectGetsNoFrameworkSteps() throws {
        let dir = try folder("native", dirs: ["ios", "android"])
        _ = try scaffold(dir)
        let workflow = try text(dir, ".github/workflows/mobile-release.yml")
        XCTAssertFalse(workflow.contains("subosito/flutter-action"))
        XCTAssertFalse(workflow.contains("setup-node"))
    }

    func testRootIOSProjectPutsFastlaneAtTheRootWithOnlyAnIOSJob() throws {
        let dir = try folder("ios-root", dirs: ["App.xcodeproj"])
        _ = try scaffold(dir)
        XCTAssertTrue(exists(dir, "fastlane/Fastfile"))
        let workflow = try text(dir, ".github/workflows/mobile-release.yml")
        XCTAssertFalse(workflow.contains("\n  android:\n"))
        XCTAssertTrue(workflow.contains("working-directory: ."))
    }

    func testRootAndroidProjectGetsOnlyAnAndroidJob() throws {
        let dir = try folder("android-root", ["settings.gradle.kts": ""], dirs: ["app"])
        _ = try scaffold(dir)
        XCTAssertTrue(exists(dir, "fastlane/Fastfile"))
        let workflow = try text(dir, ".github/workflows/mobile-release.yml")
        XCTAssertFalse(workflow.contains("\n  ios:\n"))
        XCTAssertTrue(workflow.contains("\n  android:\n"))
    }

    func testExplicitFrameworkFollowsTheFrameworkNotTheFolders() throws {
        let dir = try flutter()
        let report = try scaffold(dir, .ios)
        XCTAssertEqual(report.platforms, ["ios"])
        XCTAssertFalse(exists(dir, "android/fastlane/Fastfile"))
        let workflow = try text(dir, ".github/workflows/mobile-release.yml")
        XCTAssertFalse(workflow.contains("\n  android:\n"))
    }

    func testExpoGetsEASConfigOnlyAndNoWorkflow() throws {
        let dir = try folder(
            "expo", ["package.json": "{\"dependencies\":{\"expo\":\"~54\"}}"], dirs: ["ios", "android"])
        let report = try scaffold(dir)
        XCTAssertEqual(report.framework, .expo)
        XCTAssertTrue(exists(dir, "eas.json"))
        XCTAssertFalse(exists(dir, ".github/workflows/mobile-release.yml"))
        XCTAssertFalse(exists(dir, "ios/fastlane/Fastfile"))
        XCTAssertTrue(report.lines.contains { $0.contains("Expo uses EAS Build/Submit by default") })
    }

    func testFlutterWithoutPlatformFoldersIsRejected() throws {
        let dir = try folder("bare-flutter", ["pubspec.yaml": ""])
        assertThrows(.noPlatformFolder(framework: .flutter, directory: dir.path)) {
            _ = try scaffold(dir)
        }
    }

    func testMonorepoRootIsNotAProjectButTheAppFolderIs() throws {
        let root = try folder("mono")
        let app = try folder("mono/apps/mobile", dirs: ["ios"])
        assertThrows(.noProject(directory: root.path)) { _ = try scaffold(root) }
        _ = try scaffold(app)
        XCTAssertTrue(exists(app, "ios/fastlane/Fastfile"))
    }

    // MARK: - Gemfile

    func testFastlaneIsAppendedToAnExistingGemfileOnce() throws {
        let dir = try reactNative()
        try "source \"https://rubygems.org\"\ngem \"cocoapods\", \">= 1.13\"\n".write(
            to: dir.appendingPathComponent("Gemfile"), atomically: true, encoding: .utf8)
        _ = try scaffold(dir)
        let gemfile = try text(dir, "Gemfile")
        XCTAssertTrue(gemfile.contains("gem \"cocoapods\""))
        XCTAssertEqual(gemfile.components(separatedBy: "gem \"fastlane\"").count - 1, 1)
        _ = try scaffold(dir)
        XCTAssertEqual(try text(dir, "Gemfile").components(separatedBy: "gem \"fastlane\"").count - 1, 1)
    }

    func testCommentedOutFastlaneDoesNotCountAsInstalled() throws {
        let dir = try reactNative()
        try "source \"https://rubygems.org\"\n# gem \"fastlane\"\n".write(
            to: dir.appendingPathComponent("Gemfile"), atomically: true, encoding: .utf8)
        _ = try scaffold(dir)
        XCTAssertTrue(try text(dir, "Gemfile").contains("\ngem \"fastlane\", \"~> 2.240\""))
    }

    // MARK: - Keep, force and dry run

    func testRerunKeepsEditedFilesAndForceOverwritesThem() throws {
        let dir = try flutter()
        _ = try scaffold(dir)
        try "custom\n".write(
            to: dir.appendingPathComponent("ios/fastlane/Fastfile"), atomically: true, encoding: .utf8)
        let kept = try scaffold(dir)
        XCTAssertEqual(try text(dir, "ios/fastlane/Fastfile"), "custom\n")
        XCTAssertTrue(kept.lines.contains { $0.hasPrefix("  keep    ios/fastlane/Fastfile") })
        _ = try scaffold(dir, force: true)
        XCTAssertNotEqual(try text(dir, "ios/fastlane/Fastfile"), "custom\n")
    }

    func testDryRunWritesNothing() throws {
        let dir = try flutter()
        let report = try scaffold(dir, dryRun: true)
        XCTAssertTrue(report.dryRun)
        XCTAssertFalse(exists(dir, "ios/fastlane/Fastfile"))
        XCTAssertFalse(exists(dir, "Gemfile"))
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("  would write ") })
    }

    // MARK: - Templates

    /// The embedded templates must equal the files in templates/mobile/, so the CLI and the repo cannot drift.
    /// Regenerate with scripts/mobile-templates-embed.py.
    func testEmbeddedTemplatesMatchTheTemplateFiles() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = repo.appendingPathComponent("templates/mobile")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var onDisk: [String: String] = [:]
        for case let file as URL in enumerator where !file.hasDirectoryPath {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            var text = try String(contentsOf: file, encoding: .utf8)
            if text.hasSuffix("\n") { text.removeLast() }
            onDisk[relative] = text
        }
        XCTAssertEqual(Set(onDisk.keys), Set(MobileTemplates.files.keys), "a template was added or removed")
        for (path, text) in onDisk {
            XCTAssertEqual(MobileTemplates.files[path], text, "\(path) differs from the embedded copy")
        }
    }
}
