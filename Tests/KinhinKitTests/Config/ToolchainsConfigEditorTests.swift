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
        let yaml =
            base + """

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
        bad.tools = ["pnpm": ""]  // needs node: the engine rejects it
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
        for macOnly in ["yamllint", "fastlane", "wget"] {
            XCTAssertTrue(linux.skipped.contains(macOnly), "\(macOnly) can't be baked into a Linux image")
        }
        XCTAssertTrue(linux.installing.contains("flutter"), "flutter has a Linux (git) install")
        XCTAssertFalse(linux.skipped.contains("flutter"))
    }

    /// Tools without a defaultSpec and stacks without a defaultVersion render
    /// an em dash, never a blank cell.
    func testVersionFieldsNeverBlank() throws {
        let yaml =
            base + """

                toolchains:
                  specs: ["node"]
                  stacks: ["expo", "vercel", "cloudflare"]
                """
        var sel = try ToolchainsConfigEditor.selection(from: yaml)
        sel.tools["yamllint"] = ""
        sel.tools["fastlane"] = ""
        sel.tools["dotnet"] = ""
        // Every curated tool that the user selected gets a non-empty display
        // version, falling back to an em dash when the catalog has no default.
        for entry in ToolchainCatalog.tools where sel.tools[entry.id] != nil {
            let display = entry.defaultSpec.isEmpty ? "—" : entry.defaultSpec
            XCTAssertFalse(display.isEmpty, "\(entry.id) has no display version")
        }
        for stack in ToolchainCatalog.stacks where sel.stacks[stack.id] != nil {
            let display = stack.defaultVersion.isEmpty ? "—" : stack.defaultVersion
            XCTAssertFalse(display.isEmpty, "\(stack.id) has no display version")
        }
    }

    // MARK: Selection is populated for a full active config

    func testFullActiveConfigSelectionIsPopulated() throws {
        let yaml =
            base + """

                toolchains:
                  specs: ["node", "go", "rust", "python", "ruby", "java", "bun", "deno", "uv", "terraform", "kubectl", "pnpm", "yarn", "playwright", "cypress", "netlify-cli", "firebase-tools", "yamllint", "awscli", "supabase", "flyctl", "gcloud", "php", "composer", "dotnet", "fastlane"]
                  stacks: ["flutter", "expo", "react-native", "vercel", "cloudflare"]
                """
        let sel = try ToolchainsConfigEditor.selection(from: yaml)
        // Every curated spec root maps to a known catalog tool.
        let knownRoots = Set(sel.tools.keys).intersection(Set(ToolchainCatalog.tools.map(\.id)))
        XCTAssertEqual(
            knownRoots,
            Set([
                "node", "go", "rust", "python", "ruby", "java", "bun", "deno", "uv", "terraform", "kubectl", "pnpm",
                "yarn", "playwright", "cypress", "netlify-cli", "firebase-tools", "yamllint", "awscli", "supabase",
                "flyctl", "gcloud", "php", "composer", "dotnet", "fastlane",
            ]))
        // Every curated stack maps by id.
        XCTAssertEqual(sel.stacks.keys.sorted(), ["cloudflare", "expo", "flutter", "react-native", "vercel"])
        XCTAssertEqual(sel.extraSpecs, [] as [String])
        XCTAssertEqual(sel.extraBrew, [] as [String])
    }
}

/// Older builds wrote the whole default spec, or a "—" placeholder, into the
/// version slot (`node@node@22`, `supabase@—`); mise then rejected the spec
/// mid-bake. New writes are clean and existing configs are repaired on load.
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
            repo: "acme/widgets"
            labels: [self-hosted]
            toolchains:
              specs: ["node@node@22", "java", "supabase@—", "zig@0.13"]
              stacks: ["expo@—"]
            """)
        XCTAssertEqual(cfg.toolchains?.specs, ["node@22", "java", "supabase", "zig@0.13"])
        XCTAssertEqual(cfg.toolchains?.stacks, ["expo"])
    }
}
