import XCTest

@testable import KinhinKit

/// Whole-catalog invariants: every entry must be usable on the platforms it
/// claims, so a macOS-only Homebrew tool can't silently vanish from Linux
/// images again.
final class ToolchainCatalogInvariantTests: XCTestCase {
    private func config(specs: [String] = [], stacks: [String] = []) throws -> KinhinConfig.ToolchainsConfig {
        let specList = specs.map { "\"\($0)\"" }.joined(separator: ", ")
        let stackList = stacks.map { "\"\($0)\"" }.joined(separator: ", ")
        let cfg = try ConfigLoader.parse(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: ["self-hosted"]
            projects:
              - pattern: acme/widgets
                toolchains: {specs: [\(specList)], stacks: [\(stackList)]}
            """)
        return try XCTUnwrap(cfg.projects[0].toolchains)
    }

    func testEveryEntryHasVerifyAndUniqueID() {
        let ids = ToolchainCatalog.tools.map(\.id) + ToolchainCatalog.stacks.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate catalog ids")
        for tool in ToolchainCatalog.tools { XCTAssertFalse(tool.verify.isEmpty, "\(tool.id) has no verify") }
        for stack in ToolchainCatalog.stacks { XCTAssertFalse(stack.verify.isEmpty, "\(stack.id) has no verify") }
    }

    func testHomebrewToolsReachLinuxOnlyThroughALinuxInstaller() {
        for tool in ToolchainCatalog.tools {
            guard case .brew = tool.installer, tool.platforms.contains(.linux) else { continue }
            XCTAssertNotNil(tool.linuxInstaller, "\(tool.id) claims Linux but only installs with Homebrew")
            if case .brew? = tool.linuxInstaller { XCTFail("\(tool.id) Linux installer is Homebrew") }
        }
    }

    func testEveryCrossPlatformToolResolvesOnBothPlatforms() throws {
        // Requirements (node/java/dotnet) are validated at config load, so
        // resolve the catalog entries directly rather than through the loader.
        for tool in ToolchainCatalog.tools where Set(tool.platforms) == Set(ToolchainPlatform.allCases) {
            for platform in ToolchainPlatform.allCases {
                let selection = ToolchainCatalog.selection(
                    from: .init(specs: [tool.id]), platform: platform)
                XCTAssertFalse(selection.skippedEntries.contains(tool.id), "\(tool.id) skipped on \(platform)")
                let installs =
                    !selection.miseSpecs.isEmpty || !selection.npmPackages.isEmpty || !selection.aptPackages.isEmpty
                    || !selection.brewFormulas.isEmpty || !selection.gems.isEmpty
                XCTAssertTrue(installs, "\(tool.id) resolves to nothing on \(platform)")
                XCTAssertTrue(selection.verifications.contains(tool.verify), "\(tool.id) not verified on \(platform)")
            }
        }
    }

    func testEveryStackResolvesOnItsPlatforms() {
        for stack in ToolchainCatalog.stacks {
            for platform in ToolchainPlatform.allCases {
                let selection = ToolchainCatalog.selection(from: .init(stacks: [stack.id]), platform: platform)
                XCTAssertEqual(
                    selection.skippedEntries.contains(stack.id), !stack.platforms.contains(platform),
                    "\(stack.id) on \(platform)")
            }
        }
    }

    func testFormerlyMacOnlyToolsInstallOnLinux() throws {
        func linux(_ id: String) -> ManagedToolchainSelection {
            ToolchainCatalog.selection(from: .init(specs: [id]), platform: .linux)
        }
        XCTAssertEqual(linux("awscli").miseSpecs, ["awscli@latest"])
        XCTAssertEqual(linux("gcloud").miseSpecs, ["gcloud@latest"])
        XCTAssertEqual(linux("supabase").miseSpecs, ["supabase@latest"])
        XCTAssertEqual(linux("flyctl").miseSpecs, ["flyctl@latest"])
        XCTAssertEqual(linux("yamllint").aptPackages, ["yamllint"])
        XCTAssertEqual(linux("php").aptPackages, ["php-cli"])
        XCTAssertEqual(linux("composer").aptPackages, ["composer"])
        let fastlane = linux("fastlane")
        XCTAssertEqual(fastlane.gems, ["fastlane"])
        XCTAssertTrue(fastlane.aptPackages.contains("build-essential"), "gems need a compiler and Ruby on Linux")
    }

    func testNewMiseToolsPinVersionsAndDefault() {
        let pinned = ToolchainCatalog.selection(from: .init(specs: ["zig@0.13.0", "helm"]), platform: .linux)
        XCTAssertEqual(pinned.miseSpecs, ["zig@0.13.0", "helm@latest"])
        XCTAssertNotNil(ToolchainCatalog.tool(id: "gh"))
    }

    func testJavaRequirementIsEnforcedForJVMTools() {
        XCTAssertThrowsError(try config(specs: ["gradle"])) { error in
            XCTAssertTrue("\(error)".contains("requires java"), "\(error)")
        }
        XCTAssertNoThrow(try config(specs: ["java@temurin-21", "gradle"]))
    }
}
