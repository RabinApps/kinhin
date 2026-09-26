import AppKit
import SwiftUI

/// Advanced → Capacity.
///
/// A thin AppKit host: state and actions live in `CapacityModel`, the UI in
/// `CapacityView`.
@MainActor
final class ConfigTabViewController: NSViewController {
    let model = CapacityModel()

    /// Fired once after an Apply wrote at least one change.
    var onEdited: (() -> Void)? {
        get { model.onEdited }
        set { model.onEdited = newValue }
    }

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("ConfigTabViewController is created in code") }

    override func loadView() {
        let host = NSHostingView(rootView: CapacityView(model: model))
        // Fills whatever it is pinned into; the cards scroll.
        host.sizingOptions = []
        view = host
        reload()
    }

    func reload() { model.reload() }
}
