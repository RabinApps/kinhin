import XCTest

@testable import KinhinKit

final class ProjectToolchainDetectorTests: XCTestCase {
    func testNodePnpmTypeScriptRepo() throws {
        let result = try ProjectFixture([
            "package.json":
                #"{"engines":{"node":"^20.1"},"packageManager":"pnpm@9.1.0","devDependencies":{"typescript":"5"}}"#,
            "pnpm-lock.yaml": "",
        ]).detect()
        XCTAssertEqual(result.specs, ["node@20", "pnpm@9.1.0", "typescript@5"])
        XCTAssertTrue(result.stacks.isEmpty)
    }

    func testGoRepoWithWorkflowPin() throws {
        let result = try ProjectFixture([
            "go.mod": "module x\n\ngo 1.22.5\n",
            ".github/workflows/ci.yml":
                "jobs:\n  j:\n    steps:\n      - uses: actions/setup-go@v5\n        with:\n          go-version: 1.21\n",
        ]).detect()
        XCTAssertEqual(result.specs, ["go@1.22.5"])
    }

    func testFlutterRepo() throws {
        let result = try ProjectFixture(["pubspec.yaml": "dependencies:\n  flutter:\n    sdk: flutter\n"]).detect()
        XCTAssertEqual(result.stacks, ["flutter"])
    }

    func testGradleKotlinRepoAddsJava() throws {
        let result = try ProjectFixture(["build.gradle.kts": "plugins { kotlin(\"jvm\") }"]).detect()
        XCTAssertTrue(result.specs.contains { $0.hasPrefix("java") })
        XCTAssertTrue(result.specs.contains { $0.hasPrefix("kotlin") })
    }

    func testWorkflowOnlyRepo() throws {
        let result = try ProjectFixture([
            ".github/workflows/ci.yml": "jobs:\n  j:\n    steps:\n      - run: shellcheck x.sh\n"
        ]).detect()
        XCTAssertEqual(result.specs, ["shellcheck@latest"])
    }

    func testConflictingPinsPreferVersionFile() throws {
        let result = try ProjectFixture([".nvmrc": "22\n", "package.json": #"{"engines":{"node":"18"}}"#]).detect()
        XCTAssertEqual(result.specs, ["node@22"])
    }

    func testPlainSwiftPackageInstallsSwiftWithoutXcode() throws {
        let result = try ProjectFixture(["Package.swift": "// swift-tools-version: 6.0\nplatforms: [.macOS(.v15)]"])
            .detect()
        XCTAssertEqual(result.specs, ["swift@6.0"])
        XCTAssertTrue(result.recommendations.isEmpty)
    }

    func testSwiftVersionFileBeatsToolsVersionAndNoVersionMeansCatalogDefault() throws {
        let swiftPin = try XCTUnwrap(ToolchainCatalog.tool(id: "swift")).defaultSpec
        let pinned = try ProjectFixture([".swift-version": "5.10\n", "Package.swift": "// swift-tools-version:6.0\n"])
        XCTAssertEqual(try pinned.detect().specs, ["swift@5.10"])
        XCTAssertEqual(try ProjectFixture(["Package.swift": "// no version\n"]).detect().specs, [swiftPin])
        XCTAssertEqual(
            try ProjectFixture(["Package.swift": "// swift-tools-version:5.9\n"]).detect().specs, ["swift@5.9"])
    }

    func testXcodeProjectRecommendsXcodeImageInsteadOfSwift() throws {
        let result = try ProjectFixture([
            "App.xcodeproj/project.pbxproj": "", "Package.swift": "", ".xcode-version": "16.2\n",
        ]).detect()
        XCTAssertTrue(result.specs.isEmpty)
        XCTAssertEqual(result.recommendations.count, 1)
        XCTAssertTrue(result.recommendations[0].contains("macos-tahoe-xcode"))
        XCTAssertTrue(result.recommendations[0].contains("16.2"))
        XCTAssertTrue(result.evidence.contains { $0.source == "App.xcodeproj" })
    }

    func testXcodeSignalsFromIOSPackageWorkflowAndFlutterFolder() throws {
        XCTAssertFalse(
            try ProjectFixture(["Package.swift": "platforms: [.iOS(.v17)]"]).detect().recommendations.isEmpty)
        XCTAssertFalse(
            try ProjectFixture([".github/workflows/ci.yml": "jobs:\n  j:\n    steps:\n      - run: xcodebuild test\n"])
                .detect().recommendations.isEmpty)
        XCTAssertFalse(try ProjectFixture(["ios/Runner.xcworkspace/x": ""]).detect().recommendations.isEmpty)
    }

    func testXcrunAloneDoesNotNeedXcode() throws {
        let result = try ProjectFixture([
            "Package.swift": "",
            ".github/workflows/release.yml": "jobs:\n  j:\n    steps:\n      - run: xcrun notarytool submit x.zip\n",
        ]).detect()
        XCTAssertTrue(result.recommendations.isEmpty)
        XCTAssertEqual(result.specs, [try XCTUnwrap(ToolchainCatalog.tool(id: "swift")).defaultSpec])
    }

    func testEmptyProjectDetectsNothing() throws {
        let result = try ProjectFixture(["README.md": "hi"]).detect()
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.yaml(), "# kinhin: no toolchains detected\n")
    }

    func testMissingDirectoryThrows() {
        XCTAssertThrowsError(try ProjectToolchainDetector().detect(at: URL(fileURLWithPath: "/nonexistent/kinhin")))
    }

    func testSymlinkedManifestIsIgnored() throws {
        let fixture = try ProjectFixture(["real.json": #"{"engines":{"node":"20"}}"#])
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("package.json"),
            withDestinationURL: fixture.root.appendingPathComponent("real.json"))
        XCTAssertTrue(try fixture.detect().isEmpty)
    }

    /// Whatever the detector emits must be a valid, loadable `.kinhin.yml`.
    func testEveryCatalogEntryYieldsLoadableYAML() throws {
        let tools = ToolchainCatalog.tools.map { ToolchainHit($0.id, source: "t", reason: "t", precedence: .manifest) }
        let stacks = ToolchainCatalog.stacks.map {
            ToolchainHit($0.id, stack: true, source: "t", reason: "t", precedence: .manifest)
        }
        let result = ToolchainNormalizer.normalize(tools + stacks)
        XCTAssertTrue(result.unmatched.isEmpty)
        let loaded = try ProjectFileLoader.parse(Data(result.yaml().utf8))
        XCTAssertEqual(loaded?.specs, result.specs)
        XCTAssertEqual(loaded?.stacks, result.stacks)
    }

    func testDetectionRoundTripsAsJSON() throws {
        let result = try ProjectFixture(["go.mod": "go 1.22\n"]).detect()
        let decoded = try JSONDecoder().decode(ToolchainDetection.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded, result)
    }
}
