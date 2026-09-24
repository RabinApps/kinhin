import XCTest
@testable import KinhinKit

final class ToolchainsConfigEditorTests: XCTestCase {
    private let base = """
    # my fleet
    repo: "acme/widgets"
    labels: [self-hosted, macOS]
    max_runners: 2
    """

    func testRoundTripPreservesCommentsAndOtherKeys() throws {
        var sel = ToolchainsSelection()
        sel.tools = ["node": "22", "go": ""]
        sel.stacks = ["vercel": ""]
        sel.extraBrew = ["wget"]
        sel.shareCache = true
        let updated = try ToolchainsConfigEditor.replace(sel, in: base)
        XCTAssertTrue(updated.contains("# my fleet"))
        XCTAssertTrue(updated.contains("max_runners: 2"))
        let back = try ToolchainsConfigEditor.selection(from: updated)
        XCTAssertEqual(back.tools, ["node": "22", "go": ""])
        XCTAssertEqual(back.stacks, ["vercel": ""])
        XCTAssertEqual(back.extraBrew, ["wget"])
        XCTAssertTrue(back.shareCache)
    }

    func testEditingReplacesTheExistingSectionWithoutDuplicating() throws {
        var sel = ToolchainsSelection()
        sel.tools = ["go": "1.23.4"]
        let once = try ToolchainsConfigEditor.replace(sel, in: base)
        sel.tools = ["rust": ""]
        let twice = try ToolchainsConfigEditor.replace(sel, in: once)
        XCTAssertEqual(twice.components(separatedBy: "toolchains:").count, 2, "exactly one section")
        XCTAssertFalse(twice.contains("go@1.23.4"))
        XCTAssertTrue(twice.contains("\"rust\""))
        XCTAssertTrue(twice.contains("# my fleet"))
    }

    func testEmptySelectionRemovesTheSection() throws {
        var sel = ToolchainsSelection()
        sel.tools = ["go": ""]
        let withTools = try ToolchainsConfigEditor.replace(sel, in: base)
        let cleared = try ToolchainsConfigEditor.replace(ToolchainsSelection(), in: withTools)
        XCTAssertFalse(cleared.contains("toolchains:"))
        XCTAssertTrue(cleared.contains("repo: \"acme/widgets\""))
    }

    func testUnknownEntriesAndCachePolicySurviveAnEdit() throws {
        let yaml = base + """

        toolchains:
          specs: ["zig@0.13", "go@1.22"]
          cache:
            auto_prune: false
            max_age_days: 7
            max_gb: 10
        """
        var sel = try ToolchainsConfigEditor.selection(from: yaml)
        XCTAssertEqual(sel.extraSpecs, ["zig@0.13"], "unknown specs are kept verbatim")
        XCTAssertEqual(sel.cache?.maxAgeDays, 7)
        sel.tools["node"] = ""
        let updated = try ToolchainsConfigEditor.replace(sel, in: yaml)
        let back = try ToolchainsConfigEditor.selection(from: updated)
        XCTAssertEqual(back.extraSpecs, ["zig@0.13"])
        XCTAssertEqual(back.tools["go"], "1.22")
        XCTAssertNotNil(back.tools["node"])
        XCTAssertEqual(back.cache?.autoPrune, false)
        XCTAssertEqual(back.cache?.maxGB, 10)
    }

    func testRequirementProblemsMirrorTheEngineRule() {
        var sel = ToolchainsSelection()
        sel.tools = ["pnpm": ""]
        XCTAssertEqual(ToolchainsConfigEditor.requirementProblems(sel), ["pnpm needs node — select node too."])
        sel.tools["node"] = ""
        XCTAssertTrue(ToolchainsConfigEditor.requirementProblems(sel).isEmpty)

        var stack = ToolchainsSelection()
        stack.stacks = ["vercel": ""]
        XCTAssertFalse(ToolchainsConfigEditor.requirementProblems(stack).isEmpty)
    }

    func testApplyValidatesAndNeverWritesAnInvalidConfig() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-tc-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: url) }
        try base.write(to: url, atomically: true, encoding: .utf8)

        var bad = ToolchainsSelection()
        bad.tools = ["pnpm": ""] // needs node: the engine rejects it
        XCTAssertThrowsError(try ToolchainsConfigEditor.apply(bad, to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), base, "the file is untouched")

        var good = ToolchainsSelection()
        good.tools = ["node": "22", "pnpm": ""]
        try ToolchainsConfigEditor.apply(good, to: url)
        XCTAssertNotNil(try ConfigLoader.load(from: url).toolchains)
    }

    func testPlanSeparatesWhatEachPlatformCanInstall() {
        var sel = ToolchainsSelection()
        sel.tools = ["node": "", "go": "", "yamllint": "", "fastlane": ""]
        sel.stacks = ["flutter": ""]
        sel.extraBrew = ["wget"]
        let mac = ToolchainsConfigEditor.plan(sel, for: .macOS)
        XCTAssertTrue(mac.skipped.isEmpty)
        XCTAssertTrue(mac.installing.contains("yamllint"))
        XCTAssertTrue(mac.installing.contains("wget"))

        let linux = ToolchainsConfigEditor.plan(sel, for: .linux)
        XCTAssertTrue(linux.installing.contains("node"))
        XCTAssertTrue(linux.installing.contains("go"))
        for macOnly in ["yamllint", "fastlane", "flutter", "wget"] {
            XCTAssertTrue(linux.skipped.contains(macOnly), "\(macOnly) can't be baked into a Linux image")
        }
    }
}
