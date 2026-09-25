import XCTest
import AppKit
import KinhinKit
@testable import kinhin_app

/// Renders the real ToolchainsViewController against a scratch config and
/// asserts the catalog tool/stack rows actually appear with populated version
/// fields (the original regression: section titles showed, rows blanked).
@MainActor final class ToolchainsViewControllerTests: XCTestCase {
    private var scratch: URL!
    private var configURL: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-tc-ui-\\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        configURL = scratch.appendingPathComponent("config.yaml")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeVC() -> ToolchainsViewController {
        let c = ToolchainsViewController()
        c.configURL = configURL
        return c
    }

    /// A genuine config with a toolchains section: every catalog tool/stack
    /// must render a row with a non-empty version field.
    func testToolRowsRenderWithNonBlankVersionFields() throws {
        let yaml = """
        repo: "acme/widgets"
        labels: [self-hosted]
        toolchains:
          specs: ["node@22", "go", "pnpm"]
          stacks: ["expo", "vercel"]
        """
        try yaml.write(to: configURL, atomically: true, encoding: .utf8)

        let vc = makeVC()
        // loadView() → reload() → render() now runs
        _ = vc.view

        print("DEBUG: toolChecks=\(vc.renderedCountsForTesting)")
        let counts = vc.renderedCountsForTesting
        XCTAssertEqual(counts.tools, ToolchainCatalog.tools.count,
                       "every catalog tool must render a row: \\(counts.tools)")

        XCTAssertEqual(counts.stacks, ToolchainCatalog.stacks.count,
                       "every catalog stack must render a row: \\(counts.stacks)")

        // Every rendered tool row has a non-blank version field.
        for entry in ToolchainCatalog.tools {
            let id = entry.id
            let field = vc.renderedToolFieldValuesForTesting[id]
            XCTAssertNotNil(field, "tool row '\\(id)' must be present")
            XCTAssertFalse(field?.isEmpty ?? true,
                           "tool '\\(id)' render's version field must not be blank")
        }

        // Every rendered stack row has a non-blank version field.
        for stack in ToolchainCatalog.stacks {
            let id = stack.id
            let field = vc.renderedStackFieldValuesForTesting[id]
            XCTAssertNotNil(field, "stack row '\\(id)' must be present")
            XCTAssertFalse(field?.isEmpty ?? true,
                           "stack '\\(id)' render's version field must not be blank")
        }
    }

    /// Toggling a tool checkbox must enable/disable that tool in `working`.
    func testCheckboxTogglesTool() throws {
        try writeConfig(
            """
            repo: "acme/widgets"
            labels: [self-hosted]
            toolchains:
              specs: [\"node@22\", \"go\", \"pnpm\"]
              stacks: [\"expo\", \"vercel\"]
            """
        )
        let vc = makeVC()
        _ = vc.view

        // node@22 is selected in the config.
        XCTAssertEqual(vc.working.tools["node"], "22")

        // Uncheck the node checkbox via action.
        let check = vc.toolChecksForTesting["node"]!
        check.state = NSButton.StateValue.off
        vc.entryToggled(check)
        XCTAssertNil(vc.working.tools["node"], "unchecking a tool must remove it from selection")

        // Re-check and pin a version.
        check.state = NSButton.StateValue.on
        vc.entryToggled(check)
        XCTAssertEqual(vc.working.tools["node"], "22")
    }

    /// Clicking a checkbox must toggle the field editor and selection.
    func testCheckboxEnablesAndDisablesFieldEditor() throws {
        try writeConfig(
            """
            repo: "acme/widgets"
            labels: [self-hosted]
            toolchains:
              specs: [\"node@22\", \"go\", \"pnpm\"]
              stacks: [\"expo\", \"vercel\"]
            """
        )
        let vc = makeVC()
        _ = vc.view

        // node is selected; its version field must be enabled.
        XCTAssertEqual(vc.working.tools["node"], "22")
        XCTAssertTrue(vc.toolVersionsForTesting["node"]!.isEnabled)

        // Uncheck: field editor must be disabled and selection removed.
        vc.toolChecksForTesting["node"]!.state = NSButton.StateValue.off
        vc.entryToggled(vc.toolChecksForTesting["node"]!)
        XCTAssertNil(vc.working.tools["node"])
        XCTAssertFalse(vc.toolVersionsForTesting["node"]!.isEnabled, "version field must be disabled when tool is unchecked")

        // Re-check: field editor must be re-enabled and selection restored.
        vc.toolChecksForTesting["node"]!.state = NSButton.StateValue.on
        vc.entryToggled(vc.toolChecksForTesting["node"]!)
        XCTAssertEqual(vc.working.tools["node"], "22")
        XCTAssertTrue(vc.toolVersionsForTesting["node"]!.isEnabled)
    }

    /// Toggling a stack checkbox must enable/disable that stack in `working`.
    func testCheckboxTogglesStack() throws {
        try writeConfig(
            """
            repo: "acme/widgets"
            labels: [self-hosted]
            toolchains:
              specs: [\"node@22\", \"go\", \"pnpm\"]
              stacks: [\"expo\", \"vercel\"]
            """
        )
        let vc = makeVC()
        _ = vc.view

        // expo is selected in the config.
        XCTAssertEqual(vc.working.stacks["expo"], "")

        let check = vc.stackChecksForTesting["expo"]!
        check.state = NSButton.StateValue.off
        vc.entryToggled(check)
        XCTAssertNil(vc.working.stacks["expo"], "unchecking a stack must remove it from selection")

        // Reset the version field to blank, then re-enable the stack.
        vc.stackVersionsForTesting["expo"]!.stringValue = ""
        check.state = NSButton.StateValue.on
        vc.entryToggled(check)
        XCTAssertEqual(vc.working.stacks["expo"], "")
    }

    /// A clicked checkbox always toggles the selection (enable/disable).
    func testCheckboxToggleEnablesAndDisables() throws {
        try writeConfig(
            """
            repo: "acme/widgets"
            labels: [self-hosted]
            toolchains:
              specs: [\"node@22\", \"go\", \"pnpm\"]
              stacks: [\"expo\", \"vercel\"]
            """
        )
        let vc = makeVC()
        _ = vc.view

        vc.toggleToolForTesting("rust", on: true)
        XCTAssertNotNil(vc.working.tools["rust"], "tool must be selectable")
        vc.toggleToolForTesting("rust", on: false)
        XCTAssertNil(vc.working.tools["rust"], "tool must be deselectable")

        vc.toggleStackForTesting("flutter", on: true)
        XCTAssertNotNil(vc.working.stacks["flutter"], "stack must be selectable")
        vc.toggleStackForTesting("flutter", on: false)
        XCTAssertNil(vc.working.stacks["flutter"], "stack must be deselectable")
    }

    /// Helper: write a YAML config to the scratch config URL.
    private func writeConfig(_ yaml: String) throws {
        try yaml.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// Directly triggering render() (bypassing reload's config read) must add
    /// a row per catalog tool/stack.
    func testRenderAddsCatalogRows() throws {
        let vc = makeVC()
        // Seed the working selection with everything ON (mimics catalogSelection)
        var tools: [String: String] = [:]
        for entry in ToolchainCatalog.tools { tools[entry.id] = "" }
        vc.working.tools = tools
        var stacks: [String: String] = [:]
        for stack in ToolchainCatalog.stacks { stacks[stack.id] = "" }
        vc.working.stacks = stacks

        // Directly trigger render (bypassing reload's config read).
        vc.render()

        let counts = vc.renderedCountsForTesting
        // Every catalog tool + stack must have produced a row.
        XCTAssertEqual(counts.tools, ToolchainCatalog.tools.count,
                       "render must add a row per catalog tool")
        XCTAssertEqual(counts.stacks, ToolchainCatalog.stacks.count,
                       "render must add a row per catalog stack")
    }
}
