import XCTest

@testable import KinhinKit

final class ManifestProbeTests: XCTestCase {
    private func ids(_ files: [String: String]) throws -> Set<String> {
        let fixture = try ProjectFixture(files)
        return Set(try ManifestProbe().hits(in: fixture.reader).map { ($0.isStack ? "stack:" : "") + $0.id })
    }

    func testPackageJSONEnginesPackageManagerAndDependencies() throws {
        let fixture = try ProjectFixture([
            "package.json": """
            {"engines": {"node": ">=20"}, "packageManager": "pnpm@9.1.0+sha512.abc",
             "devDependencies": {"typescript": "^5", "eslint": "^9", "left-pad": "1"}}
            """
        ])
        let hits = try ManifestProbe().hits(in: fixture.reader)
        XCTAssertEqual(hits.first { $0.id == "node" }?.version, ">=20")
        XCTAssertEqual(hits.first { $0.id == "pnpm" }?.version, "9.1.0")
        XCTAssertTrue(hits.contains { $0.id == "typescript" })
        XCTAssertFalse(hits.contains { $0.id == "left-pad" })
    }

    func testExpoWinsOverReactNative() throws {
        let found = try ids(["package.json": #"{"dependencies": {"expo": "1", "react-native": "1"}}"#])
        XCTAssertTrue(found.contains("stack:expo"))
        XCTAssertFalse(found.contains("stack:react-native"))
    }

    func testMAUIProjectOneFolderDownIsDotnet() throws {
        let found = try ids([
            "App/App.csproj": "<Project><PropertyGroup><UseMaui>true</UseMaui></PropertyGroup></Project>"
        ])
        XCTAssertTrue(found.contains("dotnet"), "missing dotnet in \(found.sorted())")
    }

    func testKotlinPluginInASharedModuleIsDetected() throws {
        let found = try ids([
            "settings.gradle.kts": "include(\":shared\")",
            "shared/build.gradle.kts": "plugins { kotlin(\"multiplatform\") }",
        ])
        XCTAssertTrue(found.contains("kotlin"), "missing kotlin in \(found.sorted())")
    }

    func testEcosystemMarkers() throws {
        let found = try ids([
            "go.mod": "module x\n\ngo 1.22.5\n", "Cargo.toml": "", "Package.swift": "", "Gemfile": "gem 'fastlane'\n",
            "pubspec.yaml": "dependencies:\n  flutter:\n    sdk: flutter\n",
            "build.gradle.kts": "plugins { kotlin(\"jvm\") }",
            "App.csproj": "", "Dockerfile": "FROM x", "main.tf": "", "wrangler.toml": "",
        ])
        for expected in [
            "go", "rust", "swift", "ruby", "fastlane", "stack:flutter", "java", "gradle", "kotlin", "dotnet",
            "hadolint", "terraform", "stack:cloudflare",
        ] {
            XCTAssertTrue(found.contains(expected), "missing \(expected) in \(found.sorted())")
        }
    }

    func testGoDirectiveVersionAndPubspecDart() throws {
        let fixture = try ProjectFixture(["go.mod": "module x\n\ngo 1.22.5\n", "pubspec.yaml": "name: x\n"])
        let hits = try ManifestProbe().hits(in: fixture.reader)
        XCTAssertEqual(hits.first { $0.id == "go" }?.version, "1.22.5")
        XCTAssertTrue(hits.contains { $0.id == "dart" && !$0.isStack })
    }

    func testMalformedPackageJSONIsSkipped() throws {
        XCTAssertTrue(try ids(["package.json": "{nope"]).isEmpty)
    }
}
