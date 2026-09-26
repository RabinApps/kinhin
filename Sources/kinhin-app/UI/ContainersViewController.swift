import AppKit
import SwiftUI

/// Advanced → Containers.
///
/// A thin AppKit host: state and actions live in `ContainersModel`, the UI in
/// `ContainersView`.
@MainActor
final class ContainersViewController: NSViewController {
    let model = ContainersModel()

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("created in code") }

    override func loadView() {
        let host = NSHostingView(rootView: ContainersView(model: model))
        // Fills whatever it is pinned into; the cards scroll.
        host.sizingOptions = []
        view = host
    }

    func reload() { model.reload() }
}
