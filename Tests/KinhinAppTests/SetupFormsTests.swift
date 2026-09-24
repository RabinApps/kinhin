import XCTest
import AppKit
import KinhinKit
@testable import kinhin_app

/// The Setup forms and the Capacity form write real config edits — always to
/// a scratch file, never the user's config.
@MainActor
final class SetupFormsTests: XCTestCase {
    private var configURL: URL!

    override func setUp() {
        super.setUp()
        configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-setupforms-\(UUID().uuidString).yaml")
        try? """
        repo: "your-org/your-repo"
        labels: [self-hosted, macOS]
        """.write(to: configURL, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: configURL)
        super.tearDown()
    }

    private func snapshot() throws -> GeneralConfigEditor.Snapshot {
        try GeneralConfigEditor.snapshot(from: String(contentsOf: configURL, encoding: .utf8))
    }

    private func connectForm() -> ConnectFormViewController {
        let form = ConnectFormViewController()
        form.configURL = configURL
        form.hasStoredToken = { _ in false }
        _ = form.view
        return form
    }

    func testChoosingARepoWritesItToConfig() throws {
        let form = connectForm()
        var changed = 0
        form.onChanged = { changed += 1 }
        form.enterGitHubRepoForTesting("acme/api")
        XCTAssertEqual(try snapshot().repo, "acme/api")
        XCTAssertEqual(changed, 1)
        XCTAssertFalse(form.isConnected, "a repo alone is not connected — the token is missing too")
    }

    func testInvalidRepoIsRejectedAndNotWritten() throws {
        let form = connectForm()
        form.enterGitHubRepoForTesting("a/b/c")
        XCTAssertEqual(try snapshot().repo, "your-org/your-repo", "engine validation gates every write")
        XCTAssertTrue(allText(in: form.view).contains("Not saved"))
    }

    func testGiteaInstanceAndScopeAreWrittenTogether() throws {
        let form = connectForm()
        form.enterGiteaForTesting(instance: "https://git.example.com", scope: "team/repo")
        let gitea = try XCTUnwrap(snapshot().gitea)
        XCTAssertEqual(gitea.instance, "https://git.example.com")
        XCTAssertEqual(gitea.scope, "team/repo")
    }

    func testGiteaNeedsBothServerAndScopeBeforeWriting() throws {
        let form = connectForm()
        form.enterGiteaForTesting(instance: "https://git.example.com", scope: "")
        XCTAssertNil(try snapshot().gitea, "a half-filled gitea: section would make the config invalid")
    }

    func testEitherForgeAloneCountsAsConnected() throws {
        let form = connectForm()
        XCTAssertFalse(form.isConnected)

        form.enterGiteaForTesting(instance: "https://git.example.com", scope: "team/repo")
        XCTAssertFalse(form.isConnected, "Gitea details without a token are not connected")
        form.markTokensStoredForTesting(github: false, gitea: true)
        XCTAssertTrue(form.isConnected, "a Gitea-only setup can finish onboarding")
        XCTAssertEqual(try snapshot().repo, "your-org/your-repo", "no GitHub repo is required")
    }

    func testLinuxRuntimeTogglesPersist() throws {
        let form = MacToolsFormViewController()
        form.configURL = configURL
        _ = form.view
        form.setContainerForTesting(true)
        form.setDockerForTesting(true)
        XCTAssertNotNil(try snapshot().container)
        XCTAssertNotNil(try snapshot().docker)
        form.setDockerForTesting(false)
        XCTAssertNil(try snapshot().docker)
        XCTAssertNotNil(try snapshot().container)
    }

    func testCapacityWritesNothingUntilApplyThenOnce() throws {
        let form = ConfigTabViewController()
        form.configURL = configURL
        _ = form.view
        var edited = 0
        form.onEdited = { edited += 1 }

        let originalMax = try snapshot().maxRunners
        form.stageForTesting(.maxRunners(6), id: "max-runners")
        form.stageForTesting(.minRunners(2), id: "min-runners")
        form.stageForTesting(.pollInterval(45), id: "poll")
        XCTAssertTrue(form.hasPendingChanges)
        XCTAssertEqual(try snapshot().maxRunners, originalMax, "nothing is written while editing")
        XCTAssertEqual(edited, 0)

        form.applyPending()
        let snap = try snapshot()
        XCTAssertEqual(snap.maxRunners, 6)
        XCTAssertEqual(snap.minRunners, 2)
        XCTAssertEqual(snap.pollInterval, 45)
        XCTAssertEqual(edited, 1, "one engine reload for the whole batch")
        XCTAssertFalse(form.hasPendingChanges)
    }

    func testCapacityApplyHandlesMinMaxOrdering() throws {
        // Min 4 first would transiently exceed the current Max of 1.
        let form = ConfigTabViewController()
        form.configURL = configURL
        _ = form.view
        form.stageForTesting(.minRunners(4), id: "min-runners")
        form.stageForTesting(.maxRunners(8), id: "max-runners")
        form.applyPending()
        let snap = try snapshot()
        XCTAssertEqual(snap.minRunners, 4)
        XCTAssertEqual(snap.maxRunners, 8)
    }

    func testCapacityRejectedEditStaysPendingWithAnError() throws {
        let form = ConfigTabViewController()
        form.configURL = configURL
        _ = form.view
        form.stageForTesting(.minRunners(99), id: "min-runners") // far above Max
        form.applyPending()
        XCTAssertTrue(form.hasPendingChanges, "a rejected edit is kept so it can be fixed")
        XCTAssertTrue(allText(in: form.view).contains("Not applied"))
        XCTAssertEqual(try snapshot().minRunners, 0)
    }

    private func allText(in view: NSView) -> String {
        var out: [String] = []
        func walk(_ v: NSView) {
            if let t = v as? NSTextField { out.append(t.stringValue) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return out.joined(separator: "\n")
    }
}
