import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ToolchainVersionNormalizationTests: XCTestCase {
    func testNormalizedVersionStripsDoubledIdsAndPlaceholders() {
        XCTAssertEqual(ToolchainsConfigEditor.normalizedVersion("node@22", for: "node"), "22")
        XCTAssertEqual(ToolchainsConfigEditor.normalizedVersion("node@node@22", for: "node"), "22")
        XCTAssertEqual(ToolchainsConfigEditor.normalizedVersion(" 22 ", for: "node"), "22")
        XCTAssertEqual(ToolchainsConfigEditor.normalizedVersion("—", for: "supabase"), "")
        XCTAssertEqual(ToolchainsConfigEditor.normalizedVersion("-", for: "supabase"), "")
        XCTAssertEqual(ToolchainsConfigEditor.normalizedVersion("3.13", for: "python"), "3.13")
    }

    func testSpecStringsWriteCleanSpecs() {
        var selection = ToolchainsSelection()
        selection.tools["node"] = "node@22"
        selection.tools["supabase"] = "—"
        selection.stacks["expo"] = "—"
        XCTAssertEqual(ToolchainsConfigEditor.specStrings(for: selection), ["node@22", "supabase"])
        XCTAssertEqual(ToolchainsConfigEditor.stackStrings(for: selection), ["expo"])
    }

    func testLoadingRepairsAnAlreadyCorruptedConfig() throws {
        let cfg = try ConfigLoader.parse(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: [self-hosted]
            toolchains:
              specs: ["node@node@22", "java", "supabase@—", "sometool@0.13"]
              stacks: ["expo@—"]
            """)
        XCTAssertEqual(cfg.toolchains?.specs, ["node@22", "java", "supabase", "sometool@0.13"])
        XCTAssertEqual(cfg.toolchains?.stacks, ["expo"])
    }
}
