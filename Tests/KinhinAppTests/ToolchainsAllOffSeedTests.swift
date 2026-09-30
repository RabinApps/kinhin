import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Drives the wizard's all-off ToolchainsModel: every catalog tool/stack has
/// a row, starts OFF, and can be toggled and applied.
@MainActor final class ToolchainsAllOffSeedTests: XCTestCase {
    private var scratch: URL!
    private var configURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-tc-form-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        configURL = scratch.appendingPathComponent("config.yaml")
    }

    override func tearDown() async throws {
        try await super.tearDown()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeModel(
        _ yaml: String =
            "accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\nlabels: [self-hosted]\ntoolchains:\n  specs: [\"node@22\"]\n"
    ) throws -> ToolchainsModel {
        try yaml.write(to: configURL, atomically: true, encoding: .utf8)
        let model = ToolchainsModel(seed: .allOff)
        model.configURL = configURL
        model.reload()
        return model
    }

    /// Every catalog tool and stack has a row and starts OFF, even though the
    /// saved config selects node.
    func testRendersAllCatalogRowsAllOffByDefault() throws {
        let model = try makeModel()
        XCTAssertEqual(model.toolText.count, ToolchainCatalog.tools.count)
        XCTAssertEqual(model.stackText.count, ToolchainCatalog.stacks.count)
        for entry in ToolchainCatalog.tools {
            XCTAssertFalse(model.isToolOn(entry.id), "tool row '\(entry.id)' must start OFF")
        }
        for stack in ToolchainCatalog.stacks {
            XCTAssertFalse(model.isStackOn(stack.id), "stack row '\(stack.id)' must start OFF")
        }
    }

    func testCheckboxTogglesTool() throws {
        let model = try makeModel()
        XCTAssertNil(model.working.tools["node"], "tool must start OFF")

        // The selection is the bare version from the field (the default,
        // "22") — never the whole "node@22" spec, which the config writer
        // would turn into `node@node@22`.
        model.setTool("node", on: true)
        XCTAssertEqual(model.working.tools["node"], "22", "checking a tool must set its version to the default version")
        model.setTool("node", on: false)
        XCTAssertNil(model.working.tools["node"], "unchecking a tool must remove it from selection")
        model.setTool("node", on: true)
        XCTAssertEqual(model.working.tools["node"], "22", "rechecking a tool restores the default version")
    }

    func testCheckboxTogglesStack() throws {
        let model = try makeModel(
            "accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\nlabels: [self-hosted]\ntoolchains:\n  stacks: [\"expo\"]\n"
        )
        XCTAssertNil(model.working.stacks["expo"], "stack must start OFF")

        // expo takes no version, so the selection is the empty version —
        // never the "—" placeholder (which used to be written as `expo@—`).
        model.setStack("expo", on: true)
        XCTAssertEqual(model.working.stacks["expo"], "", "a stack without a version selects with an empty version")
        model.setStack("expo", on: false)
        XCTAssertNil(model.working.stacks["expo"])
        model.setStack("expo", on: true)
        XCTAssertEqual(model.working.stacks["expo"], "")
    }

    func testHooksCanEnableAndDisable() throws {
        let model = try makeModel()
        model.toggleToolForTesting("rust", version: "rust@stable", on: true)
        XCTAssertEqual(model.working.tools["rust"], "rust@stable")
        model.toggleToolForTesting("rust", on: false)
        XCTAssertNil(model.working.tools["rust"])

        model.toggleStackForTesting("flutter", on: true)
        XCTAssertEqual(model.working.stacks["flutter"], "")
        model.toggleStackForTesting("flutter", on: false)
        XCTAssertNil(model.working.stacks["flutter"])
    }

    /// Apply writes the working selection to the config.
    func testApplyWritesSelection() throws {
        let model = try makeModel()
        model.toggleToolForTesting("node", version: "22")
        model.apply()
        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(yaml.contains("node@22"), "apply must write the toolchain selection to config")
    }

    /// What lands in config.yaml after the user ticks boxes with the default
    /// field contents: bare `id@version` specs, no doubled ids, no dashes.
    func testTickedDefaultsWriteCleanSpecs() throws {
        let model = try makeModel(
            "accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\nlabels: [self-hosted]\n")
        model.setTool("node", on: true)
        model.setTool("supabase", on: true)
        model.setStack("expo", on: true)
        model.apply()

        let written = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(written.contains("\"node@22\""), written)
        XCTAssertTrue(written.contains("\"supabase\""), written)
        XCTAssertFalse(written.contains("node@node"), written)
        XCTAssertFalse(written.contains("—"), written)
        XCTAssertTrue(written.contains("\"expo\""), written)
    }
}
