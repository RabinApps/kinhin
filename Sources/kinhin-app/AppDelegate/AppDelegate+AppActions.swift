import AppKit
import KinhinKit

// App-level menu actions: logs, quit.

@MainActor
extension AppDelegate {
    @objc func openLogs() {
        let url = URL(fileURLWithPath: Paths.logsDirectory.path)
        NSWorkspace.shared.open(url)
    }

    /// "Support kinhin…": the Sponsor sheet in the main window (never a bare URL).
    @objc func openSupportPage() {
        openMainWindow()
        mainController?.tabs.present(.sponsor)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
