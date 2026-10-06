import XCTest

@testable import KinhinKit

/// The macOS runner-directory contract shared by the bake and the registration
/// script: `kinhin image prepare` fills `~/actions-runner` (the SSH bake
/// session starts in `$HOME`, so the download has to cd into it), and
/// registration puts runner 1 in that template and runners 2..N in numbered
/// copies it materializes from the template *before* cd-ing into them.
final class MacRunnerLayoutTests: XCTestCase {
    private let bakeScripts: [(name: String, script: String)] = [
        ("GitHub", RunnerBootstrap.installScript(runnerVersion: "2.337.0", runnerCount: 3)),
        ("Gitea", RunnerBootstrap.giteaRunnerInstallScript(version: "4.0.0")),
    ]

    /// Extracted at `$HOME` the runner lands beside — not in — the directory
    /// registration `cd`s into (the container bake had exactly this bug).
    func testTheBakeDownloadsInsideTheAgentDirectory() throws {
        for (name, script) in bakeScripts {
            let cd = try XCTUnwrap(script.range(of: "cd \"$HOME/"), "\(name): the bake never cd's into its agent dir")
            let download = try XCTUnwrap(script.range(of: "curl --proto-redir"), "\(name): no verified download")
            XCTAssertLessThan(cd.lowerBound, download.lowerBound, "\(name): download must land in the agent dir")
        }
    }

    /// Runner 1 lives in the baked template; `~/actions-runner-1` is never
    /// created by anything, which is what failed with
    /// `cd: /Users/admin/actions-runner-1: No such file or directory`.
    func testRunnerOneRegistersInTheTemplateAndTheRestInNumberedCopies() {
        let script = RunnerBootstrap.registrationScript(
            configureURL: "https://github.com/acme/widgets", token: "TOKEN", labels: ["x"], ephemeral: true,
            name: "kinhin-1", runnerCount: 3)
        XCTAssertTrue(script.contains("cd ~/actions-runner\n"), "runner 1 registers in the baked template")
        XCTAssertFalse(script.contains("cd ~/actions-runner-1"), "`~/actions-runner-1` never exists")
        XCTAssertTrue(script.contains("cd ~/actions-runner-2"), script)
        XCTAssertTrue(script.contains("cd ~/actions-runner-3"), script)
        XCTAssertFalse(script.contains("\"$dir"), "the script must not read an unset bash variable")
    }

    /// The numbered copies only come into existence by being copied out of the
    /// template, so the copy has to precede the `cd` that would otherwise abort
    /// the script under `set -e`.
    func testEachNumberedDirectoryIsMaterializedBeforeTheCd() throws {
        let script = RunnerBootstrap.registrationScript(
            configureURL: "https://github.com/acme/widgets", token: "TOKEN", labels: ["x"], ephemeral: true,
            name: "kinhin-1", runnerCount: 3)
        let lines = script.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for index in 2...3 {
            let cd = try XCTUnwrap(lines.firstIndex { $0 == "cd ~/actions-runner-\(index)" }, "no cd for \(index)")
            let copy = try XCTUnwrap(
                lines.firstIndex { $0.hasPrefix("cp -a ~/actions-runner/. ~/actions-runner-\(index)") },
                "runner \(index) is never copied out of the template")
            XCTAssertLessThan(copy, cd, "runner \(index): copy out of the template before cd'ing")
        }
    }
}
