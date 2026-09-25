import AppKit
import KinhinKit

// Diagnostics and log-viewer sheets.
@MainActor
extension MainTabsWindowController {
    @objc func diagnosticsClicked() {
        guard let window else { return }
        if diagnosticsController == nil {
            let controller = DiagnosticsViewController()
            let sheet = NSWindow(contentViewController: controller)
            // Plain titled mask: fullSizeContentView draws the content
            // underneath the titlebar, hiding the sheet's header.
            sheet.styleMask = [.titled]
            sheet.title = "Diagnostics"
            diagnosticsWindow = sheet
            diagnosticsController = controller
        }
        window.beginSheet(diagnosticsWindow!) { _ in }
        Task { [diagnosticsController] in await diagnosticsController?.load() }
    }

    /// Logs open as a sheet from the Fleet tab (they are a debugging aid, not
    /// a day-to-day destination).
    @objc func showLogsClicked() {
        guard let window else { return }
        if logsSheet == nil {
            let controller = LogsViewController()
            logsController = controller
            let sheet = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 460), styleMask: [.titled, .resizable],
                backing: .buffered, defer: false)
            sheet.title = "Logs"
            let content = NSView(frame: sheet.contentRect(forFrameRect: sheet.frame))
            sheet.contentView = content
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            let close = NSButton(title: "Done", target: self, action: #selector(closeLogsSheet))
            close.bezelStyle = .rounded
            close.keyEquivalent = "\r"
            let folder = NSButton(title: "Open logs folder", target: self, action: #selector(logsClicked))
            folder.bezelStyle = .rounded
            let buttons = NSStackView(views: [folder, NSView(), close])
            buttons.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(controller.view)
            content.addSubview(buttons)
            NSLayoutConstraint.activate([
                controller.view.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
                controller.view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                controller.view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                controller.view.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
                buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            ])
            sheet.minSize = NSSize(width: 480, height: 320)
            logsSheet = sheet
        }
        window.beginSheet(logsSheet!) { _ in }
        logsController?.refreshNow()
    }

    @objc func closeLogsSheet() {
        guard let sheet = logsSheet else { return }
        window?.endSheet(sheet)
    }
}
