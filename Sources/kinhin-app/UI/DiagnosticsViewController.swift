import AppKit
import KinhinKit
import SwiftUI

/// The Diagnostics sheet (Fleet tab → Diagnostics…): the full `kinhin
/// doctor` report — host, CLT, tart, containers, capacity, toolchain cache —
/// rendered with green/red chips, live probe results, and copyable fix
/// commands. Read-only; repairs stay in the setup checklist.
///
/// A thin AppKit host: the report state lives in `DiagnosticsModel` and the
/// UI in `DiagnosticsView`.
@MainActor
final class DiagnosticsViewController: NSViewController {
    let model = DiagnosticsModel()

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("DiagnosticsViewController is created in code")
    }

    override func loadView() {
        let host = NSHostingView(rootView: DiagnosticsView(model: model, onClose: { [weak self] in self?.closeSheet() }))
        host.frame = NSRect(origin: .zero, size: DiagnosticsView.size)
        view = host
        Task { await load() }
    }

    /// Runs the doctor probe set and renders the result.
    func load() async {
        await model.load()
    }

    /// Refresh only when the sheet is visible (called from the poll loop).
    func refreshIfVisible() async {
        guard isViewLoaded, view.window != nil else { return }
        await load()
    }

    /// Internal (not private) so MainWindowTests can pin the report layout
    /// with a decoded fixture — DoctorReport's section inits are internal
    /// to KinhinKit, but the type is Codable with stable field names.
    func render(_ report: DoctorReport) {
        model.render(report)
    }

    /// Sheets attached with `beginSheet` are only ended by the parent
    /// window — `dismiss(_:)` walks the presentation chain, which is empty
    /// here, so the Close button did nothing and the sheet stayed attached.
    /// (If the click lands before the sheet finished attaching, orderOut
    /// cancels the pending attach — the parent never keeps it alive.)
    func closeSheet() {
        guard let sheet = view.window else { return }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
        }
    }
}
