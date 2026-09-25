import AppKit
import SwiftUI
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Drives the real ToolchainsViewController against a scratch config and
/// asserts every catalog tool/stack has a populated version field and that
/// toggling edits the working selection (the original regression: section
/// titles showed, rows blanked).
@MainActor final class ToolchainsViewControllerTests: XCTestCase {
    private var scratch: URL!
    private var configURL: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-tc-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        configURL = scratch.appendingPathComponent("config.yaml")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private let sampleConfig = """
        repo: "acme/widgets"
        labels: [self-hosted]
        toolchains:
          specs: ["node@22", "go", "pnpm"]
          stacks: ["expo", "vercel"]
        """

    private func makeVC(_ yaml: String? = nil) throws -> ToolchainsViewController {
        try (yaml ?? sampleConfig).write(to: configURL, atomically: true, encoding: .utf8)
        let c = ToolchainsViewController()
        c.configURL = configURL
        _ = c.view
        return c
    }

    /// Every catalog tool/stack must have a row with a non-blank version field.
    func testToolRowsRenderWithNonBlankVersionFields() throws {
        let vc = try makeVC()
        XCTAssertTrue(vc.view is NSHostingView<ToolchainsView>)
        XCTAssertEqual(vc.model.toolText.count, ToolchainCatalog.tools.count)
        XCTAssertEqual(vc.model.stackText.count, ToolchainCatalog.stacks.count)
        for entry in ToolchainCatalog.tools {
            XCTAssertFalse(vc.model.toolText[entry.id]?.isEmpty ?? true, "tool '\(entry.id)' version field is blank")
        }
        for stack in ToolchainCatalog.stacks {
            XCTAssertFalse(vc.model.stackText[stack.id]?.isEmpty ?? true, "stack '\(stack.id)' version field is blank")
        }
    }

    /// Toggling a tool must enable/disable it in `working`, and its version
    /// field is only editable while it is on.
    func testCheckboxTogglesToolAndItsField() throws {
        let vc = try makeVC()
        let node = try XCTUnwrap(ToolchainCatalog.tools.first { $0.id == "node" })
        XCTAssertEqual(vc.working.tools["node"], "22", "node@22 is selected in the config")
        XCTAssertTrue(vc.model.toolFieldEnabled(node))

        vc.model.setTool("node", on: false)
        XCTAssertNil(vc.working.tools["node"], "unchecking a tool must remove it from selection")
        XCTAssertFalse(vc.model.toolFieldEnabled(node), "version field must be disabled when tool is unchecked")

        vc.model.setTool("node", on: true)
        XCTAssertEqual(vc.working.tools["node"], "22")
        XCTAssertTrue(vc.model.toolFieldEnabled(node))
    }

    /// Toggling a stack must enable/disable it in `working`.
    func testCheckboxTogglesStack() throws {
        let vc = try makeVC()
        XCTAssertEqual(vc.working.stacks["expo"], "")

        vc.model.setStack("expo", on: false)
        XCTAssertNil(vc.working.stacks["expo"], "unchecking a stack must remove it from selection")

        vc.model.stackText["expo"] = ""
        vc.model.setStack("expo", on: true)
        XCTAssertEqual(vc.working.stacks["expo"], "")
    }

    func testToggleHooksSelectAndDeselect() throws {
        let vc = try makeVC()
        vc.model.toggleToolForTesting("rust", on: true)
        XCTAssertNotNil(vc.working.tools["rust"], "tool must be selectable")
        vc.model.toggleToolForTesting("rust", on: false)
        XCTAssertNil(vc.working.tools["rust"], "tool must be deselectable")

        vc.model.toggleStackForTesting("flutter", on: true)
        XCTAssertNotNil(vc.working.stacks["flutter"], "stack must be selectable")
        vc.model.toggleStackForTesting("flutter", on: false)
        XCTAssertNil(vc.working.stacks["flutter"], "stack must be deselectable")
    }

    /// Typing a version pins it on a selected tool, and is stored bare.
    func testEditingAVersionUpdatesTheSelection() throws {
        let vc = try makeVC()
        vc.model.setToolText("node", "20")
        XCTAssertEqual(vc.working.tools["node"], "20")
        XCTAssertTrue(vc.hasPendingChanges)
    }

    /// Resetting field texts from a populated selection yields a row per
    /// catalog tool/stack.
    func testResetFieldTextsCoversTheWholeCatalog() throws {
        let vc = try makeVC("repo: \"acme/widgets\"\nlabels: [self-hosted]\n")
        vc.model.working = vc.model.catalogSelection()
        vc.model.resetFieldTexts()
        XCTAssertEqual(vc.model.toolText.count, ToolchainCatalog.tools.count)
        XCTAssertEqual(vc.model.stackText.count, ToolchainCatalog.stacks.count)
    }
}
