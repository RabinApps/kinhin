import XCTest

@testable import KinhinKit

final class ToolchainNormalizerTests: XCTestCase {
    private func hit(
        _ id: String, stack: Bool = false, _ version: String? = nil, _ precedence: ToolchainHit.Precedence = .manifest
    ) -> ToolchainHit {
        ToolchainHit(id, stack: stack, version: version, source: "f", reason: "r", precedence: precedence)
    }

    func testCleanVersion() {
        XCTAssertEqual(ToolchainNormalizer.cleanVersion("v22.1.0", tool: "node"), "22.1.0")
        XCTAssertEqual(ToolchainNormalizer.cleanVersion("^20.1", tool: "node"), "20")
        XCTAssertEqual(ToolchainNormalizer.cleanVersion(">=20", tool: "node"), "20")
        XCTAssertEqual(ToolchainNormalizer.cleanVersion(">=3.11,<4", tool: "python"), "3.11")
        XCTAssertEqual(ToolchainNormalizer.cleanVersion("20.x", tool: "node"), "20")
        XCTAssertEqual(ToolchainNormalizer.cleanVersion("~> 1.5", tool: "terraform"), "1.5")
        XCTAssertEqual(ToolchainNormalizer.cleanVersion("^5.4.2", tool: "typescript"), "5.4")
        XCTAssertEqual(ToolchainNormalizer.cleanVersion("1.8", tool: "java"), "8")
        XCTAssertEqual(ToolchainNormalizer.cleanVersion(">=3.24.0", tool: "flutter"), "3.24.0")
        XCTAssertNil(ToolchainNormalizer.cleanVersion(">=3.24", tool: "flutter"))
        XCTAssertNil(ToolchainNormalizer.cleanVersion("workspace:*", tool: "typescript"))
        XCTAssertNil(ToolchainNormalizer.cleanVersion("lts/*", tool: "node"))
        XCTAssertNil(ToolchainNormalizer.cleanVersion("$(evil)", tool: "node"))
        XCTAssertNil(ToolchainNormalizer.cleanVersion(nil, tool: "node"))
    }

    func testVersionFileBeatsManifestBeatsWorkflow() {
        let result = ToolchainNormalizer.normalize([
            hit("node", "20", .workflow), hit("node", "22", .versionFile), hit("node", "18", .manifest),
        ])
        XCTAssertEqual(result.specs, ["node@22"])
        XCTAssertEqual(result.evidence.count, 3)
    }

    func testUnversionedHighPrecedenceDoesNotBlockLowerVersion() {
        let result = ToolchainNormalizer.normalize([hit("node", nil, .manifest), hit("node", "20", .workflow)])
        XCTAssertEqual(result.specs, ["node@20"])
    }

    func testNoVersionFallsBackToCatalogDefault() throws {
        let pin = try XCTUnwrap(ToolchainCatalog.tool(id: "node")).defaultSpec
        XCTAssertEqual(ToolchainNormalizer.normalize([hit("node")]).specs, [pin])
    }

    func testRuntimesAreAddedForTheLoader() {
        let result = ToolchainNormalizer.normalize([hit("pnpm"), hit("vercel", stack: true), hit("gradle")])
        XCTAssertEqual(Set(result.specs.map { $0.split(separator: "@")[0] }), ["pnpm", "node", "gradle", "java"])
        XCTAssertEqual(result.stacks, ["vercel"])
        XCTAssertTrue(result.evidence.contains { $0.source == "implied" && $0.reason == "required by pnpm" })
    }

    func testUnknownToolsAreUnmatchedAndNeverEmitted() {
        let result = ToolchainNormalizer.normalize([hit("cowsay"), hit("go", "1.22")])
        XCTAssertEqual(result.unmatched, ["cowsay"])
        XCTAssertEqual(result.specs, ["go@1.22"])
    }

    func testBrewInstalledToolsTakeNoVersion() {
        XCTAssertEqual(ToolchainNormalizer.normalize([hit("php", "8.3")]).specs, ["php"])
    }

    func testOutputIsSortedAndDeduplicated() {
        let result = ToolchainNormalizer.normalize([hit("go", "1.22"), hit("deno"), hit("go", "1.22")])
        XCTAssertEqual(result.specs, result.specs.sorted())
        XCTAssertEqual(result.specs.filter { $0.hasPrefix("go@") }.count, 1)
    }
}
