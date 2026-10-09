import AppKit
import KinhinKit

// The application menu shown in the menu bar while the app has a window.

@MainActor
extension AppDelegate {
    // MARK: - Application menu (menu bar while the app has a window)

    /// The standard macOS menu bar: app menu (Settings…, Quit), Edit (so
    /// copy/paste work in every field), and Window. Installed once; the
    /// status-bar menu below is separate.
    func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let app = NSMenu(title: "kinhin")
        app.addItem(
            withTitle: String(localized: "About kinhin", bundle: .l10n, comment: "App menu item"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        app.addItem(.separator())
        let settings = app.addItem(
            withTitle: String(localized: "Settings…", bundle: .l10n, comment: "App menu item"),
            action: #selector(openSettingsTab), keyEquivalent: ",")
        settings.target = self
        let setup = app.addItem(
            withTitle: String(localized: "Setup…", bundle: .l10n, comment: "App menu item"),
            action: #selector(openSetupTab), keyEquivalent: "")
        setup.target = self
        app.addItem(.separator())
        app.addItem(
            withTitle: String(localized: "Hide kinhin", bundle: .l10n, comment: "App menu item"),
            action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(
            withTitle: String(localized: "Hide Others", bundle: .l10n, comment: "App menu item"),
            action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(
            withTitle: String(localized: "Show All", bundle: .l10n, comment: "App menu item"),
            action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(
            withTitle: String(localized: "Quit kinhin", bundle: .l10n, comment: "App menu item"),
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(
            title: String(localized: "Edit", bundle: .l10n, comment: "Title of the Edit menu in the menu bar"))
        edit.addItem(
            withTitle: String(localized: "Undo", bundle: .l10n, comment: "Edit menu item"), action: Selector(("undo:")),
            keyEquivalent: "z")
        let redo = edit.addItem(
            withTitle: String(localized: "Redo", bundle: .l10n, comment: "Edit menu item"), action: Selector(("redo:")),
            keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(
            withTitle: String(localized: "Cut", bundle: .l10n, comment: "Edit menu item"),
            action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(
            withTitle: String(localized: "Copy", bundle: .l10n, comment: "Edit menu item"),
            action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(
            withTitle: String(localized: "Paste", bundle: .l10n, comment: "Edit menu item"),
            action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(
            withTitle: String(localized: "Select All", bundle: .l10n, comment: "Edit menu item"),
            action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(
            title: String(localized: "Window", bundle: .l10n, comment: "Title of the Window menu in the menu bar"))
        window.addItem(
            withTitle: String(localized: "Minimize", bundle: .l10n, comment: "Window menu item"),
            action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(
            withTitle: String(localized: "Close", bundle: .l10n, comment: "Window menu item"),
            action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        let helpItem = NSMenuItem()
        let help = NSMenu(
            title: String(localized: "Help", bundle: .l10n, comment: "Title of the Help menu in the menu bar"))
        help.addItem(
            withTitle: String(localized: "Support kinhin…", bundle: .l10n, comment: "Help menu item"),
            action: #selector(openSupportPage), keyEquivalent: ""
        ).target = self
        help.addItem(
            withTitle: String(localized: "Become a Sponsor…", bundle: .l10n, comment: "Help menu item"),
            action: #selector(openBecomeSponsor), keyEquivalent: ""
        ).target =
            self
        helpItem.submenu = help
        main.addItem(helpItem)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    // MARK: - Menu state

    /// Start/Stop/Pause/Resume only enable when they would do something.
    /// While a start/stop is in flight the fleet controls all disable — the
    /// command already runs; a second one would double-drive it.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let id = item.identifier?.rawValue else { return true }
        if fleet.pendingFleetAction != nil {
            switch id {
            case "startFleet", "stopFleet", "pauseResumeFleet": return false
            default: break
            }
        }
        let running = fleet.status?.running ?? false
        switch id {
        case "startFleet": return !running
        case "stopFleet": return running
        case "pauseResumeFleet": return running
        default: return true
        }
    }
}
