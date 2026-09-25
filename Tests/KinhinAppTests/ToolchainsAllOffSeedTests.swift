import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Drives the wizard's all-off ToolchainsViewController: every catalog
/// tool/stack has a row, starts OFF, and can be toggled and applied.
@MainActor final class ToolchainsAllOffSeedTests: XCTestCase {
    private var scratch: URL!
    private var configURL: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-tc-form-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        configURL = scratch.appendingPathComponent("config.yaml")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeVC(_ yaml: String = "repo: \"acme/widgets\"\nlabels: [self-hosted]\ntoolchains:\n  specs: [\"node@22\"]\n") throws
        -> ToolchainsViewController
    {
        try yaml.write(to: configURL, atomically: true, encoding: .utf8)
        let c = ToolchainsViewController(seed: .allOff)
        c.configURL = configURL
        _ = c.view
        return c
    }

    /// Every catalog tool and stack has a row and starts OFF, even though the
    /// saved config selects node.
    func testRendersAllCatalogRowsAllOffByDefault() throws {
        let vc = try makeVC()
        XCTAssertEqual(vc.model.toolText.count, ToolchainCatalog.tools.count)
        XCTAssertEqual(vc.model.stackText.count, ToolchainCatalog.stacks.count)
        for entry in ToolchainCatalog.tools {
            XCTAssertFalse(vc.model.isToolOn(entry.id), "tool row '\(entry.id)' must start OFF")
        }
        for stack in ToolchainCatalog.stacks {
            XCTAssertFalse(vc.model.isStackOn(stack.id), "stack row '\(stack.id)' must start OFF")
        }
    }

    func testCheckboxTogglesTool() throws {
        let vc = try makeVC()
        XCTAssertNil(vc.working.tools["node"], "tool must start OFF")

        // The selection is the bare version from the field (the default,
        // "22") — never the whole "node@22" spec, which the config writer
        // would turn into `node@node@22`.
        vc.model.setTool("node", on: true)
        XCTAssertEqual(vc.working.tools["node"], "22", "checking a tool must set its version to the default version")
        vc.model.setTool("node", on: false)
        XCTAssertNil(vc.working.tools["node"], "unchecking a tool must remove it from selection")
        vc.model.setTool("node", on: true)
        XCTAssertEqual(vc.working.tools["node"], "22", "rechecking a tool restores the default version")
    }

    func testCheckboxTogglesStack() throws {
        let vc = try makeVC("repo: \"acme/widgets\"\nlabels: [self-hosted]\ntoolchains:\n  stacks: [\"expo\"]\n")
        XCTAssertNil(vc.working.stacks["expo"], "stack must start OFF")

        // expo takes no version, so the selection is the empty version —
        // never the "—" placeholder (which used to be written as `expo@—`).
        vc.model.setStack("expo", on: true)
        XCTAssertEqual(vc.working.stacks["expo"], "", "a stack without a version selects with an empty version")
        vc.model.setStack("expo", on: false)
        XCTAssertNil(vc.working.stacks["expo"])
        vc.model.setStack("expo", on: true)
        XCTAssertEqual(vc.working.stacks["expo"], "")
    }

    func testHooksCanEnableAndDisable() throws {
        let vc = try makeVC()
        vc.model.toggleToolForTesting("rust", version: "rust@stable", on: true)
        XCTAssertEqual(vc.working.tools["rust"], "rust@stable")
        vc.model.toggleToolForTesting("rust", on: false)
        XCTAssertNil(vc.working.tools["rust"])

        vc.model.toggleStackForTesting("flutter", on: true)
        XCTAssertEqual(vc.working.stacks["flutter"], "")
        vc.model.toggleStackForTesting("flutter", on: false)
        XCTAssertNil(vc.working.stacks["flutter"])
    }

    /// Apply writes the working selection to the config.
    func testApplyWritesSelection() throws {
        let vc = try makeVC()
        vc.model.toggleToolForTesting("node", version: "22")
        vc.apply()
        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(yaml.contains("node@22"), "apply must write the toolchain selection to config")
    }

    /// What lands in config.yaml after the user ticks boxes with the default
    /// field contents: bare `id@version` specs, no doubled ids, no dashes.
    func testTickedDefaultsWriteCleanSpecs() throws {
        let vc = try makeVC("repo: \"acme/widgets\"\nlabels: [self-hosted]\n")
        vc.model.setTool("node", on: true)
        vc.model.setTool("supabase", on: true)
        vc.model.setStack("expo", on: true)
        vc.apply()

        let written = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(written.contains("\"node@22\""), written)
        XCTAssertTrue(written.contains("\"supabase\""), written)
        XCTAssertFalse(written.contains("node@node"), written)
        XCTAssertFalse(written.contains("—"), written)
        XCTAssertTrue(written.contains("\"expo\""), written)
    }
}
