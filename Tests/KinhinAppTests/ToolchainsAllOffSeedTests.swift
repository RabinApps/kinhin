import AppKit
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Renders the wizard's all-off ToolchainsViewController and
/// asserts the catalog tool/stack rows actually appear and can be toggled.
@MainActor final class ToolchainsAllOffSeedTests: XCTestCase {
    private var scratch: URL!
    private var configURL: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-tc-form-\\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        configURL = scratch.appendingPathComponent("config.yaml")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeVC() -> ToolchainsViewController {
        let c = ToolchainsViewController(seed: .allOff)
        c.configURL = configURL
        return c
    }

    /// Rendering the form must add one row per catalog tool and stack, with
    /// every tool and version field initially OFF (the form's default).
    func testRendersAllCatalogRowsAllOffByDefault() throws {
        try writeConfig(
            "repo: \"acme/widgets\"\nlabels: [self-hosted]\ntoolchains:\n  specs: [\"node@22\"]\n"
        )

        let vc = makeVC()
        _ = vc.view

        let counts = vc.renderedCountsForTesting
        XCTAssertEqual(
            counts.tools, ToolchainCatalog.tools.count,
            "every catalog tool must render a row: \\(counts.tools)")
        XCTAssertEqual(
            counts.stacks, ToolchainCatalog.stacks.count,
            "every catalog stack must render a row: \\(counts.stacks)")

        // All tool rows off by default.
        for entry in ToolchainCatalog.tools {
            let check = vc.toolChecksForTesting[entry.id]!
            XCTAssertEqual(check.state, .off, "tool row '\\(entry.id)' must start OFF")
            XCTAssertNotNil(vc.toolVersionsForTesting[entry.id], "tool row '\\(entry.id)' must have a version field")
        }

        // All stack rows off by default.
        for stack in ToolchainCatalog.stacks {
            let check = vc.stackChecksForTesting[stack.id]!
            XCTAssertEqual(check.state, .off, "stack row '\\(stack.id)' must start OFF")
            XCTAssertNotNil(vc.stackVersionsForTesting[stack.id], "stack row '\\(stack.id)' must have a version field")
        }
    }

    /// Toggling a tool checkbox must enable/disable that tool in `working`.
    func testCheckboxTogglesTool() throws {
        try writeConfig(
            "repo: \"acme/widgets\"\nlabels: [self-hosted]\ntoolchains:\n  specs: [\"node@22\"]\n"
        )
        let vc = makeVC()
        _ = vc.view

        // The form starts all OFF; the config's node is not pre-selected.
        XCTAssertNil(vc.working.tools["node"], "tool must start OFF")

        // Check the tool on: the selection is the bare version from the field
        // (the default, "22") — never the whole "node@22" spec, which the
        // config writer would turn into `node@node@22`.
        vc.toolChecksForTesting["node"]!.state = NSButton.StateValue.on
        vc.entryToggled(vc.toolChecksForTesting["node"]!)
        XCTAssertEqual(vc.working.tools["node"], "22", "checking a tool must set its version to the default version")

        // Uncheck.
        vc.toolChecksForTesting["node"]!.state = NSButton.StateValue.off
        vc.entryToggled(vc.toolChecksForTesting["node"]!)
        XCTAssertNil(vc.working.tools["node"], "unchecking a tool must remove it from selection")

        // Re-check: selection is again the default spec.
        vc.toolChecksForTesting["node"]!.state = NSButton.StateValue.on
        vc.entryToggled(vc.toolChecksForTesting["node"]!)
        XCTAssertEqual(vc.working.tools["node"], "22", "rechecking a tool restores the default version")
    }

    /// Toggling a stack checkbox must enable/disable that stack in `working`.
    func testCheckboxTogglesStack() throws {
        try writeConfig(
            "repo: \"acme/widgets\"\nlabels: [self-hosted]\ntoolchains:\n  stacks: [\"expo\"]\n"
        )
        let vc = makeVC()
        _ = vc.view

        // The form starts all OFF; the config's expo is not pre-selected.
        XCTAssertNil(vc.working.stacks["expo"], "stack must start OFF")

        // Check the stack on: expo takes no version, so the selection is the
        // empty version — never the "—" placeholder (which used to be written
        // to config as `expo@—`).
        vc.stackChecksForTesting["expo"]!.state = NSButton.StateValue.on
        vc.entryToggled(vc.stackChecksForTesting["expo"]!)
        XCTAssertEqual(vc.working.stacks["expo"], "", "a stack without a version selects with an empty version")

        // Uncheck.
        vc.stackChecksForTesting["expo"]!.state = NSButton.StateValue.off
        vc.entryToggled(vc.stackChecksForTesting["expo"]!)
        XCTAssertNil(vc.working.stacks["expo"], "unchecking a stack must remove it from selection")

        // Re-check: selection is again the placeholder.
        vc.stackChecksForTesting["expo"]!.state = NSButton.StateValue.on
        vc.entryToggled(vc.stackChecksForTesting["expo"]!)
        XCTAssertEqual(vc.working.stacks["expo"], "", "rechecking a stack selects it with an empty version")
    }

    /// A tool/stack must be deselectable after being selected.
    func testCheckboxCanEnableAndDisable() throws {
        try writeConfig(
            "repo: \"acme/widgets\"\nlabels: [self-hosted]\ntoolchains:\n  specs: [\"node@22\"]\n"
        )
        let vc = makeVC()
        _ = vc.view

        vc.toggleToolForTesting("rust", version: "rust@stable", on: true)
        XCTAssertEqual(vc.working.tools["rust"], "rust@stable", "tool must be selectable (default spec)")
        vc.toggleToolForTesting("rust", on: false)
        XCTAssertNil(vc.working.tools["rust"], "tool must be deselectable")

        vc.toggleStackForTesting("flutter", on: true)
        XCTAssertEqual(vc.working.stacks["flutter"], "", "stack must be selectable (blank = default)")
        vc.toggleStackForTesting("flutter", on: false)
        XCTAssertNil(vc.working.stacks["flutter"], "stack must be deselectable")
    }

    /// Apply writes the working selection to the config.
    func testApplyWritesSelection() throws {
        try writeConfig(
            "repo: \"acme/widgets\"\nlabels: [self-hosted]\ntoolchains:\n  specs: [\"node@22\"]\n"
        )
        let vc = makeVC()
        _ = vc.view

        vc.toggleToolForTesting("node", on: true)
        vc.toggleToolForTesting("node", version: "22")
        vc.apply()
        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(yaml.contains("node@22"), "apply must write the toolchain selection to config")
    }

    // MARK: - Test helpers

    private func writeConfig(_ yaml: String) throws {
        try yaml.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// What lands in config.yaml after the user ticks boxes with the default
    /// field contents: bare `id@version` specs, no doubled ids, no dashes.
    func testTickedDefaultsWriteCleanSpecs() throws {
        try writeConfig("repo: \"acme/widgets\"\nlabels: [self-hosted]\n")
        let vc = makeVC()
        _ = vc.view
        for id in ["node", "supabase"] {
            vc.toolChecksForTesting[id]!.state = .on
            vc.entryToggled(vc.toolChecksForTesting[id]!)
        }
        vc.stackChecksForTesting["expo"]!.state = .on
        vc.entryToggled(vc.stackChecksForTesting["expo"]!)
        vc.apply()

        let written = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(written.contains("\"node@22\""), written)
        XCTAssertTrue(written.contains("\"supabase\""), written)
        XCTAssertFalse(written.contains("node@node"), written)
        XCTAssertFalse(written.contains("—"), written)
        XCTAssertTrue(written.contains("\"expo\""), written)
    }
}
