import AppKit
import KinhinKit
import SwiftUI

/// The Logs tab: a pretty, searchable view of kinhin's own log stream.
/// Renders Log ring-buffer entries (mirrored from kinhin.log) with level
/// coloring, pauseable auto-refresh, level filtering, and incremental text
/// search — no more digging through `kinhin logs` output in Terminal.
///
/// A thin AppKit host: state lives in `LogsModel`, the UI in `LogsView`.
@MainActor
final class LogsViewController: NSViewController {
    let model = LogsModel()
    private var refreshTimer: Timer?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("LogsViewController is created in code")
    }

    override func loadView() {
        let host = NSHostingView(rootView: LogsView(model: model))
        // Fills whatever it is pinned into; the log scrolls.
        host.sizingOptions = []
        view = host
        refreshNow()
        startTimer()
    }

    private func startTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            // A repeating timer outlives its owner; stop it once the view is gone.
            guard self != nil else { return timer.invalidate() }
            Task { @MainActor [weak self] in
                self?.refreshNow()
            }
        }
    }

    /// Re-reads the log ring buffer and re-renders. When follow is on and
    /// the user is at the bottom, the view stays pinned to the newest line.
    func refreshNow() {
        model.refresh()
    }
}
