import AppKit
import SwiftUI
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Drives the real ToolchainsModel against a scratch config and asserts every
/// catalog tool/stack has a populated version field and that toggling edits
/// the working selection (the original regression: section titles showed,
/// rows blanked).
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

    private func makeModel(_ yaml: String? = nil) throws -> ToolchainsModel {
        try (yaml ?? sampleConfig).write(to: configURL, atomically: true, encoding: .utf8)
        let model = ToolchainsModel()
        model.configURL = configURL
        model.reload()
        return model
    }

    /// Every catalog tool/stack must have a row with a non-blank version field.
    func testToolRowsRenderWithNonBlankVersionFields() throws {
        let model = try makeModel()
        XCTAssertEqual(model.toolText.count, ToolchainCatalog.tools.count)
        XCTAssertEqual(model.stackText.count, ToolchainCatalog.stacks.count)
        for entry in ToolchainCatalog.tools {
            XCTAssertFalse(model.toolText[entry.id]?.isEmpty ?? true, "tool '\(entry.id)' version field is blank")
        }
        for stack in ToolchainCatalog.stacks {
            XCTAssertFalse(model.stackText[stack.id]?.isEmpty ?? true, "stack '\(stack.id)' version field is blank")
        }
    }

    /// Toggling a tool must enable/disable it in `working`, and its version
    /// field is only editable while it is on.
    func testCheckboxTogglesToolAndItsField() throws {
        let model = try makeModel()
        let node = try XCTUnwrap(ToolchainCatalog.tools.first { $0.id == "node" })
        XCTAssertEqual(model.working.tools["node"], "22", "node@22 is selected in the config")
        XCTAssertTrue(model.toolFieldEnabled(node))

        model.setTool("node", on: false)
        XCTAssertNil(model.working.tools["node"], "unchecking a tool must remove it from selection")
        XCTAssertFalse(model.toolFieldEnabled(node), "version field must be disabled when tool is unchecked")

        model.setTool("node", on: true)
        XCTAssertEqual(model.working.tools["node"], "22")
        XCTAssertTrue(model.toolFieldEnabled(node))
    }

    /// Toggling a stack must enable/disable it in `working`.
    func testCheckboxTogglesStack() throws {
        let model = try makeModel()
        XCTAssertEqual(model.working.stacks["expo"], "")

        model.setStack("expo", on: false)
        XCTAssertNil(model.working.stacks["expo"], "unchecking a stack must remove it from selection")

        model.stackText["expo"] = ""
        model.setStack("expo", on: true)
        XCTAssertEqual(model.working.stacks["expo"], "")
    }

    func testToggleHooksSelectAndDeselect() throws {
        let model = try makeModel()
        model.toggleToolForTesting("rust", on: true)
        XCTAssertNotNil(model.working.tools["rust"], "tool must be selectable")
        model.toggleToolForTesting("rust", on: false)
        XCTAssertNil(model.working.tools["rust"], "tool must be deselectable")

        model.toggleStackForTesting("flutter", on: true)
        XCTAssertNotNil(model.working.stacks["flutter"], "stack must be selectable")
        model.toggleStackForTesting("flutter", on: false)
        XCTAssertNil(model.working.stacks["flutter"], "stack must be deselectable")
    }

    /// Typing a version pins it on a selected tool, and is stored bare.
    func testEditingAVersionUpdatesTheSelection() throws {
        let model = try makeModel()
        model.setToolText("node", "20")
        XCTAssertEqual(model.working.tools["node"], "20")
        XCTAssertTrue(model.hasPendingChanges)
    }

    /// Resetting field texts from a populated selection yields a row per
    /// catalog tool/stack.
    func testResetFieldTextsCoversTheWholeCatalog() throws {
        let model = try makeModel("repo: \"acme/widgets\"\nlabels: [self-hosted]\n")
        model.working = model.catalogSelection()
        model.resetFieldTexts()
        XCTAssertEqual(model.toolText.count, ToolchainCatalog.tools.count)
        XCTAssertEqual(model.stackText.count, ToolchainCatalog.stacks.count)
    }
}
