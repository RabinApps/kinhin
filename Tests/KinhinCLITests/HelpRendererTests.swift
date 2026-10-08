import XCTest

@testable import kinhin

final class HelpRendererTests: XCTestCase {
    private func allPages() -> [(path: [String], text: String)] {
        var pages: [(path: [String], text: String)] = []
        func visit(_ specs: [CommandSpec], _ prefix: [String]) {
            for spec in specs {
                let path = prefix + [spec.name]
                pages.append((path, HelpRenderer.page(for: spec, path: path)))
                visit(spec.subcommands, path)
            }
        }
        visit(CommandCatalog.all, [])
        return pages
    }

    func testNoHelpLineExceedsTheColumnBudget() {
        let limit = HelpRenderer.columns
        for line in helpText().split(separator: "\n", omittingEmptySubsequences: false) {
            XCTAssertLessThanOrEqual(line.count, limit, "overview: \(line)")
        }
        for page in allPages() {
            for line in page.text.split(separator: "\n", omittingEmptySubsequences: false) {
                XCTAssertLessThanOrEqual(line.count, limit, "\(page.path.joined(separator: " ")): \(line)")
            }
        }
    }

    func testEveryVisibleCommandAppearsInTheOverview() {
        let help = helpText()
        func visit(_ specs: [CommandSpec], _ prefix: [String]) {
            for spec in specs where !spec.hidden {
                let path = prefix + [spec.name]
                if spec.subcommands.isEmpty {
                    XCTAssertTrue(help.contains(path.joined(separator: " ")), "\(path) missing from help")
                }
                visit(spec.subcommands, path)
            }
        }
        visit(CommandCatalog.all, [])
        XCTAssertFalse(help.contains("setup-status"), "the legacy spelling is not advertised")
        XCTAssertFalse(help.contains("--token "), "the discouraged flag is not advertised")
    }

    func testOverviewIsGroupedAndShort() {
        let lines = helpText().split(separator: "\n", omittingEmptySubsequences: false)
        for group in HelpGroup.allCases {
            XCTAssertTrue(lines.contains { $0 == "\(group.title):" }, "\(group.title) section missing")
        }
        XCTAssertLessThan(lines.count, 90, "the overview is a command index; details are in per-command help")
    }

    func testEveryPageStartsWithItsUsage() {
        for page in allPages() {
            let command = page.path.joined(separator: " ")
            XCTAssertTrue(page.text.hasPrefix("kinhin \(command) — "), command)
            XCTAssertTrue(page.text.contains("usage: kinhin \(command)"), "\(command) has no usage line")
        }
    }

    func testPageListsVisibleFlagsWithSummariesAndHidesTheRest() {
        let page = helpText(for: ["auth", "set"])
        XCTAssertTrue(page.contains("--token-stdin"))
        XCTAssertFalse(page.contains("--token "), page)
        XCTAssertTrue(page.contains("--github|--gitlab"), "forge flags collapse into one row")
        let prepare = helpText(for: ["image", "prepare"])
        XCTAssertFalse(prepare.contains("--source"), "hidden flags stay off the page")
    }

    func testUsageLinesWrapAndStayAccurate() {
        let lines = HelpRenderer.usageLines(
            for: CommandCatalog.topLevel("cleanup")!, path: ["cleanup"])
        XCTAssertEqual(lines, ["usage: kinhin cleanup [--vms] [--image] [--cache] [--all] [--yes] [--json]"])
        XCTAssertGreaterThan(
            HelpRenderer.usageLines(
                for: CommandCatalog.topLevel("image")!.subcommand(named: "prepare")!, path: ["image", "prepare"]
            ).count, 1)
    }

    func testWrapBreaksOnWordsAndIndentsContinuations() {
        XCTAssertEqual(HelpRenderer.wrap("aaa bbb ccc", width: 7, indent: "  "), ["aaa bbb", "  ccc"])
        XCTAssertEqual(HelpRenderer.wrap("", width: 10, indent: ""), [])
    }

    // MARK: - Golden copy

    private var goldenURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/golden/cli-help.txt")
    }

    /// `scripts/golden/cli-help.txt` is what `scripts/docs-sync.sh` copies into
    /// the website (it has no Swift toolchain), and what `skills-lint.sh`
    /// reads the command vocabulary from. Regenerate it with
    /// `KINHIN_UPDATE_GOLDEN=1 swift test --filter HelpRendererTests`.
    func testCheckedInHelpMatchesTheGeneratedHelp() throws {
        let generated = helpText() + "\n"
        if ProcessInfo.processInfo.environment["KINHIN_UPDATE_GOLDEN"] != nil {
            try generated.write(to: goldenURL, atomically: true, encoding: .utf8)
        }
        let checkedIn = try String(contentsOf: goldenURL, encoding: .utf8)
        XCTAssertEqual(
            checkedIn, generated,
            "scripts/golden/cli-help.txt is stale; run: KINHIN_UPDATE_GOLDEN=1 swift test --filter HelpRendererTests, then scripts/docs-sync.sh"
        )
    }
}
