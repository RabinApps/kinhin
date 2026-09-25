import AppKit
import KinhinKit

// App-level menu actions: logs, tart repair, quit.

@MainActor
extension AppDelegate {
    @objc func openLogs() {
        let url = URL(fileURLWithPath: Paths.logsDirectory.path)
        NSWorkspace.shared.open(url)
    }

    /// When tart is installed but Gatekeeper kills it on launch, the wizard
    /// alone isn't enough — run the repair directly (no UI dependency).
    func runTartRepairIfNeeded() {
        let cfg = try? ConfigLoader.load()
        guard TartController.isInstalled(configuredPath: cfg?.tartPath) else { return }
        Task {
            let health = await TartHealthProbe(configuredPath: cfg?.tartPath).check()
            guard health == .killedOnLaunch else { return }
            Log.error("app", "tart is killed on launch; starting automatic rollback repair")
            let repair = TartHealthProbe.repairs(for: .killedOnLaunch)[0]
            let repairRunner = SetupWindowController(embeddedIn: NSView())
            repairRunner.runRepair(
                repair,
                progressTitle: "Tart is blocked by Gatekeeper — rolling back to the notarized Cirrus Labs build…"
            )
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
