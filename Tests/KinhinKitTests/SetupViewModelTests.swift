import XCTest
@testable import KinhinKit

final class SetupViewModelTests: XCTestCase {
    // MARK: Fixtures

    private func check(id: String, ok: Bool, action: String? = nil, detail: String = "some detail") -> SetupCheckResult {
        SetupCheckResult(id: id, title: "T", ok: ok, detail: detail, action: action)
    }

    private func allOK() -> [SetupCheckResult] {
        ["arch", "clt", "tart", "config", "token", "image"].map { check(id: $0, ok: true) }
    }

    // MARK: Row mapping

    func testRowMapsContractFieldsAndResolvesActionTitle() {
        let row = SetupRowViewModel(check: check(id: "tart", ok: false, action: "install_tart"))
        XCTAssertEqual(row.id, "tart")
        XCTAssertEqual(row.isSatisfied, false)
        XCTAssertEqual(row.actionTitle, "Install via Homebrew")
        XCTAssertFalse(row.isPlaceholder)
    }

    func testRowSubtitleFallsBackToCheckingMessageWhenDetailEmpty() {
        let row = SetupRowViewModel(check: check(id: "x", ok: false, detail: ""))
        XCTAssertEqual(row.subtitle, SetupRowViewModel.checkingSubtitle)
    }

    // MARK: Placeholders

    func testLoadingStateProducesSixPlaceholdersAndNoStart() {
        let vm = SetupViewModel(checks: [], isLoading: true)
        XCTAssertEqual(vm.rows.count, 6)
        XCTAssertTrue(vm.rows.allSatisfy(\.isPlaceholder))
        XCTAssertFalse(vm.canStart)
        XCTAssertEqual(vm.progressFraction, 0)
        XCTAssertEqual(vm.headline, SetupRowViewModel.checkingSubtitle)
    }

    func testPlaceholderFactoryMarksRowsAsPlaceholder() {
        let row = SetupRowViewModel.placeholder(index: 2)
        XCTAssertEqual(row.id, "placeholder-2")
        XCTAssertTrue(row.isPlaceholder)
        XCTAssertEqual(row.actionTitle, nil)
    }

    // MARK: Progress + headline

    func testProgressFractionCountsSatisfiedChecks() {
        let checks = [
            check(id: "a", ok: true),
            check(id: "b", ok: true),
            check(id: "c", ok: false, action: "create_config"),
            check(id: "d", ok: true),
        ]
        let vm = SetupViewModel(checks: checks)
        XCTAssertEqual(vm.progressFraction, 0.75, accuracy: 0.0001)
        XCTAssertEqual(vm.headline, "1 of 4 steps to go.")
    }

    func testAllSatisfiedMeansReadyWithStartEnabled() {
        let vm = SetupViewModel(checks: allOK())
        XCTAssertTrue(vm.ready)
        XCTAssertTrue(vm.canStart)
        XCTAssertEqual(vm.progressFraction, 1.0)
        XCTAssertEqual(vm.headline, "You're all set — start the fleet whenever you like.")
    }

    func testAllFailedShowsFullRemainingCount() {
        let checks = (0 ..< 5).map { check(id: "\($0)", ok: false) }
        let vm = SetupViewModel(checks: checks)
        XCTAssertEqual(vm.headline, "5 of 5 steps to go.")
        XCTAssertFalse(vm.canStart)
        XCTAssertEqual(vm.progressFraction, 0.0)
    }

    // MARK: Accessibility

    func testRowAccessibilityLabels() {
        let satisfied = SetupRowViewModel(check: check(id: "arch", ok: true))
        XCTAssertEqual(satisfied.accessibilityLabel, "T: OK")

        let pending = SetupRowViewModel(check: check(id: "tart", ok: false, action: "install_tart", detail: "required"))
        XCTAssertEqual(pending.accessibilityLabel, "T: needs setup — action available: Install via Homebrew")

        let placeholder = SetupRowViewModel.placeholder(index: 0)
        XCTAssertEqual(placeholder.accessibilityLabel, "Checking this Mac…")
    }

    // MARK: Layout

    func testLayoutFitsFiveCardsWithoutScrolling() {
        XCTAssertGreaterThanOrEqual(SetupWindowLayout.visibleRowCount(), 5)
    }

    func testLayoutFitsSixCardsWithoutScrolling() {
        XCTAssertGreaterThanOrEqual(SetupWindowLayout.visibleRowCount(), 6)
    }

    /// The checklist can exceed six rows (gitea-token, container rows). The
    /// window stays at the six-row default and the list scrolls (Runtimes
    /// pane style) — this pins the pane's visible capacity so overflow is a
    /// scroll, never clipped content or a resized window.
    func testDefaultWindowShowsSixRowsAndOverflowScrolls() {
        let baseHeight = SetupWindowLayout.windowHeight(forRows: 6)
        XCTAssertEqual(
            SetupWindowLayout.visibleRowCount(windowHeight: baseHeight), 6,
            "the fixed default window shows exactly six cards")
        XCTAssertGreaterThan(
            SetupWindowLayout.windowHeight(forRows: 9), baseHeight,
            "nine cards need more height than the pane provides — they must scroll, not resize the window")
    }

    func testLayoutGrowsWindowForMoreRows() {
        let five = SetupWindowLayout.windowHeight(forRows: 5)
        let eight = SetupWindowLayout.windowHeight(forRows: 8)
        XCTAssertGreaterThan(eight, five)
        // Monotonic and never smaller than the default.
        XCTAssertGreaterThanOrEqual(five, SetupWindowLayout.windowHeight)
    }

    func testLayoutConstantsAreSane() {
        XCTAssertGreaterThan(SetupWindowLayout.windowWidth, 400)
        XCTAssertGreaterThan(SetupWindowLayout.cardHeight, 40)
        XCTAssertLessThan(SetupWindowLayout.cardHeight, 100)
    }
}