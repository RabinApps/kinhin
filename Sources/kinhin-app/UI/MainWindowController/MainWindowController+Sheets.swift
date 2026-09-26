import AppKit
import KinhinKit
import SwiftUI

// Diagnostics and log-viewer sheets. The sheets are owned end to end here:
// window construction, the models behind the SwiftUI views, the refresh
// timer, and the sheet-detach logic (see closeDiagnosticsSheet).
@MainActor
extension MainTabsWindowController {
    @objc func diagnosticsClicked() {
        guard let window else { return }
        if diagnosticsWindow == nil {
            makeDiagnosticsSheet()
        }
        guard let sheet = diagnosticsWindow else { return }
        window.beginSheet(sheet) { _ in }
        Task { [diagnosticsModel] in await diagnosticsModel?.load() }
    }

    /// Builds the Diagnostics sheet window and its model (called lazily on
    /// first open; the sheet is reused afterwards).
    func makeDiagnosticsSheet() {
        let model = DiagnosticsModel()
        diagnosticsModel = model
        let host = NSHostingView(
            rootView: DiagnosticsView(model: model, onClose: { [weak self] in self?.closeDiagnosticsSheet() }))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: DiagnosticsView.size)
        // Plain titled mask: fullSizeContentView draws the content
        // underneath the titlebar, hiding the sheet's header.
        let sheet = NSWindow(
            contentRect: NSRect(origin: .zero, size: DiagnosticsView.size),
            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Diagnostics"
        sheet.contentView = host
        diagnosticsWindow = sheet
    }

    /// Refresh only when the sheet exists (called from the poll loop). The
    /// view stays installed in the sheet window after a close so the sheet
    /// can re-open, so existing-but-hidden refreshes are fine.
    func refreshDiagnosticsIfVisible() async {
        guard diagnosticsWindow != nil else { return }
        await diagnosticsModel?.load()
    }

    /// Sheets attached with `beginSheet` are only ended by the parent
    /// window — `dismiss(_:)` walks the presentation chain, which is empty
    /// here, so the Close button did nothing and the sheet stayed attached.
    /// (If the click lands before the sheet finished attaching, orderOut
    /// cancels the pending attach — the parent never keeps it alive.)
    func closeDiagnosticsSheet() {
        guard let sheet = diagnosticsWindow else { return }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
        }
    }

    /// Logs open as a sheet from the Fleet tab (they are a debugging aid, not
    /// a day-to-day destination).
    @objc func showLogsClicked() {
        guard let window else { return }
        if logsSheet == nil {
            let model = LogsModel()
            logsModel = model
            let host = NSHostingView(rootView: LogsView(model: model))
            // Fills whatever it is pinned into; the log scrolls.
            host.sizingOptions = []
            let sheet = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 460), styleMask: [.titled, .resizable],
                backing: .buffered, defer: false)
            sheet.title = "Logs"
            let content = NSView(frame: sheet.contentRect(forFrameRect: sheet.frame))
            sheet.contentView = content
            host.translatesAutoresizingMaskIntoConstraints = false
            let close = NSButton(title: "Done", target: self, action: #selector(closeLogsSheet))
            close.bezelStyle = .rounded
            close.keyEquivalent = "\r"
            let folder = NSButton(title: "Open logs folder", target: self, action: #selector(logsClicked))
            folder.bezelStyle = .rounded
            let buttons = NSStackView(views: [folder, NSView(), close])
            buttons.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(host)
            content.addSubview(buttons)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
                host.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                host.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                host.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
                buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            ])
            sheet.minSize = NSSize(width: 480, height: 320)
            logsSheet = sheet
            startLogsTimer()
        }
        guard let sheet = logsSheet else { return }
        window.beginSheet(sheet) { _ in }
        logsModel?.refresh()
    }

    /// Re-reads the log ring buffer every second while the sheet exists
    /// (the view stays live so the sheet can re-open, matching the sheet).
    private func startLogsTimer() {
        logsRefreshTimer?.invalidate()
        logsRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.logsModel?.refresh()
            }
        }
    }

    @objc func closeLogsSheet() {
        guard let sheet = logsSheet else { return }
        window?.endSheet(sheet)
        logsRefreshTimer?.invalidate()
        logsRefreshTimer = nil
    }
}
