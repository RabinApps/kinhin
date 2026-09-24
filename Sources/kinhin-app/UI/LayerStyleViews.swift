import AppKit

// MARK: Layer-style views

// CALayer colors (backgroundColor, borderColor) are resolved ONCE at
// assignment — when a card styles its layer with `color.cgColor` and the
// system later switches light↔dark, the frozen color no longer matches the
// UI around it. These subclasses route all layer styling through
// updateLayer(), which AppKit re-runs on every display update (including
// appearance changes), so dynamic NSColors always re-resolve to the current
// appearance. They deliberately keep semantic NSColors (controlBackgroundColor,
// separatorColor, systemGreen…) — never raw RGB.

/// A plain view whose layer is styled by a closure re-run on every update.
/// The closure receives the view's layer directly, so callers never capture
/// the view itself.
@MainActor
final class LayerStyleView: NSView {
    var styleLayer: ((CALayer) -> Void)?

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("LayerStyleView is created in code")
    }

    override func updateLayer() {
        if let layer { styleLayer?(layer) }
    }
}

/// A label whose layer (e.g. a tinted status disc or warning strip) is
/// styled by a closure re-run on every update. The closure receives the
/// label's layer directly, so callers never capture the label itself.
@MainActor
final class LayerStyleLabel: NSTextField {
    private let styleLayer: (CALayer) -> Void

    /// Plain label (the `NSTextField(labelWithString:)` shape).
    init(labelWithString string: String, style: @escaping (CALayer) -> Void) {
        styleLayer = style
        super.init(frame: .zero)
        stringValue = string
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
        wantsLayer = true
    }

    /// Wrapping label (the `NSTextField(wrappingLabelWithString:)` shape).
    init(wrappingLabelWithString string: String, style: @escaping (CALayer) -> Void) {
        styleLayer = style
        super.init(frame: .zero)
        stringValue = string
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
        cell?.wraps = true
        lineBreakMode = .byWordWrapping
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("LayerStyleLabel is created in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        if let layer { styleLayer(layer) }
    }
}
