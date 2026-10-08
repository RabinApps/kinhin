import XCTest

@testable import kinhin

/// Invariants of the declarative command table, and a source audit that keeps
/// it honest: a flag a command body reads must be declared in the catalog (or
/// the resolver would reject it), and a declared flag must be read somewhere.
final class CommandCatalogTests: XCTestCase {
    private func walk(_ specs: [CommandSpec], path: [String] = [], _ visit: (CommandSpec, [String]) -> Void) {
        for spec in specs {
            visit(spec, path + [spec.name])
            walk(spec.subcommands, path: path + [spec.name], visit)
        }
    }

    func testNamesAndAliasesAreUniqueAmongSiblings() {
        func check(_ specs: [CommandSpec], _ context: String) {
            var seen: Set<String> = []
            for spec in specs {
                for token in [spec.name] + spec.aliases {
                    XCTAssertTrue(seen.insert(token).inserted, "\(token) is declared twice under \(context)")
                }
                check(spec.subcommands, spec.name)
            }
        }
        check(CommandCatalog.all, "the top level")
    }

    func testFlagSpellingsAreUniqueWithinACommandAndLookLikeFlags() {
        walk(CommandCatalog.all) { spec, path in
            var seen: Set<String> = []
            for flag in spec.flags {
                for name in flag.names {
                    XCTAssertTrue(name.hasPrefix("-"), "\(path): \(name) is not a flag")
                    XCTAssertTrue(seen.insert(name).inserted, "\(path): \(name) declared twice")
                    XCTAssertNotEqual(name, "--help", "\(path): --help is global")
                    XCTAssertNotEqual(name, "-h", "\(path): -h is global")
                }
                if flag.arity != .none {
                    XCTAssertFalse(flag.placeholder.isEmpty, "\(path): \(flag.name) has no placeholder")
                }
                if !flag.hidden { XCTAssertFalse(flag.summary.isEmpty, "\(path): \(flag.name) has no summary") }
            }
        }
    }

    func testEveryCommandHasASummaryAndDefaultsPointAtRealSubcommands() {
        walk(CommandCatalog.all) { spec, path in
            XCTAssertFalse(spec.summary.isEmpty, "\(path) has no summary")
            XCTAssertLessThanOrEqual(spec.summary.count, 64, "\(path): keep the summary to one overview line")
            if let name = spec.defaultSubcommand {
                XCTAssertNotNil(spec.subcommand(named: name), "\(path): default '\(name)' is not a subcommand")
            }
            if spec.requiresSubcommand { XCTAssertFalse(spec.subcommands.isEmpty, "\(path)") }
        }
    }

    func testTheNormalizedSetupStatusSpellingExistsBesideItsLegacyAlias() throws {
        let setup = try XCTUnwrap(CommandCatalog.topLevel("setup"))
        XCTAssertNotNil(setup.subcommand(named: "status"))
        let legacy = try XCTUnwrap(CommandCatalog.topLevel("setup-status"))
        XCTAssertTrue(legacy.hidden, "the old spelling works but is not advertised")
        XCTAssertEqual(legacy.flags, setup.subcommand(named: "status")?.flags)
    }

    func testTokenOnTheCommandLineIsAcceptedButNotAdvertised() throws {
        let set = try XCTUnwrap(CommandCatalog.topLevel("auth")?.subcommand(named: "set"))
        XCTAssertEqual(set.flag(matching: "--token")?.hidden, true)
        XCTAssertEqual(set.flag(matching: "--token-stdin")?.hidden, false)
        XCTAssertFalse(helpText(for: ["auth", "set"]).contains("--token TOKEN"))
        XCTAssertFalse(helpText(for: ["auth", "add"]).contains("--token TOKEN"))
    }

    func testStatusLikeCommandsAllTakeJSONAndQuiet() throws {
        for path in [
            ["status"], ["stop"], ["pause"], ["resume"], ["doctor"], ["auth", "status"], ["setup", "status"],
        ] {
            let spec = try XCTUnwrap(
                path.dropFirst().reduce(CommandCatalog.topLevel(path[0])) { $0?.subcommand(named: $1) }, "\(path)")
            XCTAssertNotNil(spec.flag(matching: "--json"), "\(path) --json")
            XCTAssertNotNil(spec.flag(matching: "--quiet"), "\(path) --quiet")
            XCTAssertNotNil(spec.flag(matching: "-q"), "\(path) -q")
        }
    }

    // MARK: - Source audit

    private var commandsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/kinhin/Commands")
    }

    private func swiftFiles(under directory: URL) -> [URL] {
        let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    func testEveryFlagLiteralInACommandBodyIsDeclaredInTheCatalog() throws {
        var declared: Set<String> = ["--help", "-h", "--"]
        walk(CommandCatalog.all) { spec, _ in declared.formUnion(spec.flags.flatMap(\.names)) }
        let pattern = try NSRegularExpression(pattern: "\"(--?[A-Za-z][A-Za-z-]*)\"")
        // Aliases that are command names, not flags, live in the catalog's own file.
        let bodies = swiftFiles(under: commandsDirectory).filter { !$0.path.contains("/Spec/") }
        XCTAssertFalse(bodies.isEmpty)
        for file in bodies {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let literal = String(text[Range(match.range(at: 1), in: text)!])
                // Command spellings that happen to start with a dash.
                if ["--version", "-v"].contains(literal) { continue }
                // `--FORGE` style flags are generated from ForgeID in the catalog.
                if declared.contains(literal) { continue }
                XCTFail("\(file.lastPathComponent) reads \(literal), which CommandCatalog does not declare")
            }
        }
    }
}
