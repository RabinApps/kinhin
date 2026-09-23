import AppKit
import KinhinKit

// Menu bar app entry point. Uses AppKit directly so the bare SPM executable
// works without an app bundle; the Release DMG wraps it with an Info.plist.
// Declared with @main (not main.swift) so the target is importable from
// unit tests (Tests/KinhinAppTests).
//
// IMPORTANT: this main must stay *synchronous*. Entering app.run() from async
// top-level code parks the program's main task on the main actor forever, and
// every Task {} in the app (which inherits that actor) starves behind it —
// the setup checklist silently never computes, updates never check, etc.
// `MainActor.assumeIsolated` keeps that guarantee: the main() method is not
// async, so nothing parks the main task before app.run() takes the thread.

/// Crash visibility: if the app dies from an uncaught exception, the user
/// must see why — never a silent bounce-and-vanish.
func kinhinPresentCrashAlert(reason: String) {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "kinhin hit a problem"
    alert.informativeText = "kinhin crashed unexpectedly:\n\n\(reason)\n\nLogs: ~/Library/Application Support/Kinhin/logs/"
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

@main
struct kinhinApp {
    static func main() {
        NSSetUncaughtExceptionHandler { exception in
            kinhinPresentCrashAlert(reason: exception.reason ?? exception.name.rawValue)
        }

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            Log.info("main", "entering app run loop")
            app.run()
        }
    }
}
