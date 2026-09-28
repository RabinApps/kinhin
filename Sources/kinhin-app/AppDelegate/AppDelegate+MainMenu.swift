import AppKit
import KinhinKit

// The application menu shown in the menu bar while the app has a window.

@MainActor
extension AppDelegate {
    // MARK: Application menu (menu bar while the app has a window)

    /// The standard macOS menu bar: app menu (Settings…, Quit), Edit (so
    /// copy/paste work in every field), and Window. Installed once; the
    /// status-bar menu below is separate.
    func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let app = NSMenu(title: "kinhin")
        app.addItem(
            withTitle: "About kinhin", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        app.addItem(.separator())
        let settings = app.addItem(withTitle: "Settings…", action: #selector(openSettingsTab), keyEquivalent: ",")
        settings.target = self
        let setup = app.addItem(withTitle: "Setup…", action: #selector(openSetupTab), keyEquivalent: "")
        setup.target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide kinhin", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit kinhin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    // MARK: Menu state

    /// Start/Stop/Pause/Resume only enable when they would do something.
    /// While a start/stop is in flight the fleet controls all disable — the
    /// command already runs; a second one would double-drive it.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let id = item.identifier?.rawValue else { return true }
        if pendingFleetAction != nil {
            switch id {
            case "startFleet", "stopFleet", "pauseFleet", "resumeFleet": return false
            default: break
            }
        }
        let running = lastStatus?.running ?? false
        let paused = lastStatus?.paused ?? false
        switch id {
        case "startFleet": return !running
        case "stopFleet": return running
        case "pauseFleet": return running && !paused
        case "resumeFleet": return running && paused
        default: return true
        }
    }
}
