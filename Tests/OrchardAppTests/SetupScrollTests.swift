import XCTest
import AppKit
import OrchardKit
@testable import orchard_app

/// The setup checklist scrolls (Runtimes-pane style) instead of the window
/// growing: optional rows — gitea-token, the container rows — push the list
/// past the six cards the fixed window shows, and the overflow must be
/// reachable by scrolling, never clipped.
@MainActor
final class SetupScrollTests: XCTestCase {
    private func checks(_ count: Int) -> [SetupCheckResult] {
        (0..<count).map {
            SetupCheckResult(id: "check-\($0)", title: "Row \($0)", ok: true, detail: "detail", action: nil)
        }
    }

    private func scrollView(in controller: SetupWindowController) -> NSScrollView? {
        guard let contentView = controller.window?.contentView else { return nil }
        return contentView.subviews.compactMap { $0 as? NSScrollView }.first
    }

    private func renderedStack(in controller: SetupWindowController) -> NSStackView? {
        scrollView(in: controller)?.documentView as? NSStackView
    }

    func testWindowHeightIsFixedAtTheSixRowDefault() {
        let controller = SetupWindowController()
        let contentHeight = controller.window?.contentView?.frame.height ?? 0
        XCTAssertEqual(
            contentHeight, SetupWindowLayout.windowHeight(forRows: 6), accuracy: 0.5,
            "the window content stays at the six-row default — rows beyond that scroll")
    }

    func testWindowDoesNotGrowWhenTheChecklistExceedsSixRows() {
        let controller = SetupWindowController()
        let before = controller.window?.frame.height ?? 0

        controller.render(viewModel: SetupViewModel(checks: checks(9)))
        controller.window?.layoutIfNeeded()

        XCTAssertEqual(
            controller.window?.frame.height ?? 0, before, accuracy: 0.5,
            "nine checklist rows must not resize the window — the pane scrolls instead (the old clipping bug's fix, done the other way)")
        XCTAssertEqual(renderedStack(in: controller)?.arrangedSubviews.count, 9, "every row is present in the document view")
    }

    func testNineRowsOverflowThePaneAndScroll() {
        let controller = SetupWindowController()
        controller.render(viewModel: SetupViewModel(checks: checks(9)))

        guard let scroll = scrollView(in: controller), let stack = renderedStack(in: controller) else {
            return XCTFail("the checklist must live in a scroll view (Runtimes-pane style)")
        }
        // Headless windows get no automatic layout pass — resolve the
        // constraint tree so the scroll view's frame and contentSize are real.
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            stack.frame.height, scroll.contentSize.height,
            "nine cards exceed the six-row pane, so the content must be taller than the visible area")
        XCTAssertNotNil(scroll.verticalScroller, "a vertical scroller must be available for the overflow")
    }

    func testSixRowsFitWithoutScrolling() {
        let controller = SetupWindowController()
        controller.render(viewModel: SetupViewModel(checks: checks(6)))

        guard let scroll = scrollView(in: controller), let stack = renderedStack(in: controller) else {
            return XCTFail("the checklist must live in a scroll view (Runtimes-pane style)")
        }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(
            stack.frame.height, scroll.contentSize.height + 0.5,
            "the base six-row checklist fills the pane exactly — no needless scrolling")
    }
}
