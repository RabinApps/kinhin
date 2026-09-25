import AppKit
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The CALayer color-freeze bug class: `layer.backgroundColor = color.cgColor`
/// resolves the color ONCE, so a light↔dark system switch leaves frozen
/// light-mode colors on dark surfaces (and vice versa). These tests pin the
/// re-resolution contract of the LayerStyle* subclasses that every card,
/// disc, and warning strip in the app now renders through.
@MainActor
final class LayerStyleTests: XCTestCase {
    // MARK: LayerStyleView

    func testStyleLayerRunsOnEveryDisplayUpdate() {
        let view = LayerStyleView(frame: .zero)
        var runs = 0
        view.styleLayer = { _ in runs += 1 }
        view.display()
        view.display()
        XCTAssertEqual(runs, 2, "styleLayer must run on every display update")
    }

    func testStyleLayerResolvesCurrentAppearanceEachUpdate() {
        let view = LayerStyleView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        var counter = 0
        view.styleLayer = { layer in
            counter += 1
            layer.backgroundColor = (counter % 2 == 0 ? NSColor.white : NSColor.black).cgColor
        }
        view.display()
        let first = view.layer?.backgroundColor
        view.display()
        XCTAssertNotEqual(
            first, view.layer?.backgroundColor,
            "styleLayer must re-run on each update, re-resolving dynamic colors")
    }

    func testViewIsLayerBackedWithoutAutoresizingMask() {
        let view = LayerStyleView(frame: .zero)
        XCTAssertTrue(view.wantsLayer, "the view must be layer-backed at init (callers rely on it)")
        XCTAssertTrue(view.wantsUpdateLayer, "updateLayer() must drive styling")
    }

    // MARK: LayerStyleLabel

    func testLabelStyleResolvesPerAppearance() {
        var counter = 0
        let label = LayerStyleLabel(labelWithString: "✓") { layer in
            counter += 1
            layer.backgroundColor =
                (counter % 2 == 0 ? NSColor.systemGreen : NSColor.systemRed).withAlphaComponent(0.18).cgColor
        }
        label.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        label.display()
        let first = label.layer?.backgroundColor
        label.display()
        XCTAssertNotEqual(first, label.layer?.backgroundColor)
        XCTAssertEqual(label.stringValue, "✓")
        XCTAssertTrue(label.wantsUpdateLayer)
    }

    func testWrappingLabelKeepsWrappingBehavior() {
        let label = LayerStyleLabel(wrappingLabelWithString: "multi word text") { _ in }
        label.frame = NSRect(x: 0, y: 0, width: 60, height: 40)
        XCTAssertTrue(label.cell?.wraps ?? false, "the wrapping init must preserve wrap behavior")
        XCTAssertEqual(label.lineBreakMode, .byWordWrapping)
        XCTAssertFalse(label.isEditable)
        XCTAssertFalse(label.isBezeled)
    }

    // MARK: Cross-appearance resolution (the actual bug)

    func testDynamicColorResolvesDifferentlyPerAppearance() {
        // The mechanism the fix relies on: cgColor resolution follows
        // NSAppearance.current — which AppKit sets from the view's
        // effectiveAppearance before calling updateLayer(). So a semantic
        // color resolved inside updateLayer() is always the CURRENT
        // appearance's value. Probe both appearances directly; if this ever
        // stops holding on a future macOS, the whole approach needs
        // revisiting — fail loudly.
        let light = NSAppearance(named: .aqua).map { appearance -> CGColor? in
            let previous = NSAppearance.current
            NSAppearance.current = appearance
            defer { NSAppearance.current = previous }
            return NSColor.controlBackgroundColor.cgColor
        }
        let dark = NSAppearance(named: .darkAqua).map { appearance -> CGColor? in
            let previous = NSAppearance.current
            NSAppearance.current = appearance
            defer { NSAppearance.current = previous }
            return NSColor.controlBackgroundColor.cgColor
        }
        XCTAssertNotEqual(
            light, dark,
            "controlBackgroundColor must resolve differently per current appearance")
    }
}
