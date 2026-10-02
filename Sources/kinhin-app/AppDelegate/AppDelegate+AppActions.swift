import AppKit
import KinhinKit

// App-level menu actions: logs, quit.

@MainActor
extension AppDelegate {
    @objc func openLogs() {
        let url = URL(fileURLWithPath: Paths.logsDirectory.path)
        NSWorkspace.shared.open(url)
    }

    @objc func openSupportPage() {
        NSWorkspace.shared.open(SupportLinks.githubSponsors.url)
    }

    @objc func openBecomeSponsor() {
        NSWorkspace.shared.open(SupportLinks.becomeASponsor.url)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
