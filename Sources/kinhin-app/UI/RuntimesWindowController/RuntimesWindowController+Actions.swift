import AppKit
import KinhinKit

// Route add/remove and other pane actions.
@MainActor
extension RuntimesWindowController {
    // MARK: Actions

    @objc func editConfigClicked() {
        NSWorkspace.shared.open(configURL)
    }

    /// Runtimes a route can target: tart always, plus whichever Linux runtimes
    /// the config has enabled (a route to an unconfigured runtime is rejected).
    static func routableRuntimes(in config: KinhinConfig?) -> [RuntimeID] {
        var ids: [RuntimeID] = [.tart]
        if config?.container != nil { ids.append(.appleContainer) }
        if config?.docker != nil { ids.append(.docker) }
        // Host needs no config section (only the runner agent, which the
        // setup checklist installs); the route itself carries the consent.
        ids.append(.host)
        return ids
    }

    static let hostConsentTitle = "Host only: run this repo's code directly on my Mac, unisolated"

    /// The Add Route form with explicit frames (an NSAlert accessory view
    /// doesn't run Auto Layout, so stack views collapse there).
    static func makeRouteForm(runtimes: [RuntimeID]) -> (
        view: NSView, pattern: NSTextField, popup: NSPopUpButton, consent: NSButton
    ) {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 96))
        let pattern = NSTextField(frame: NSRect(x: 0, y: 72, width: 340, height: 24))
        pattern.placeholderString = "acme/api  or  acme/api@Workflow Name"
        pattern.setAccessibilityLabel("Repo or workflow pattern")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 40, width: 340, height: 26), pullsDown: false)
        for id in runtimes {
            switch id {
            case .tart: popup.addItem(withTitle: "tart — macOS VMs")
            case .appleContainer: popup.addItem(withTitle: "Apple container — Linux")
            case .docker: popup.addItem(withTitle: "Docker — Linux")
            case .host: popup.addItem(withTitle: "Host — this Mac, no isolation")
            }
            popup.lastItem?.representedObject = id.rawValue
        }
        popup.setAccessibilityLabel("Runtime to use")
        let consent = NSButton(checkboxWithTitle: Self.hostConsentTitle, target: nil, action: nil)
        consent.frame = NSRect(x: 0, y: 4, width: 340, height: 28)
        consent.font = .systemFont(ofSize: 11)
        consent.setAccessibilityLabel("Host route consent")
        view.addSubview(pattern)
        view.addSubview(popup)
        view.addSubview(consent)
        return (view, pattern, popup, consent)
    }

    @objc func addRouteClicked() {
        guard viewModel != nil, let parsed = parsedConfigForPreview else {
            presentNotice(
                "Routes are still loading",
                "The runtime list hasn't loaded yet. If this keeps happening, check that config.yaml exists and is valid (Advanced → App → Open config file)."
            )
            reload()
            return
        }
        let runtimes = Self.routableRuntimes(in: parsed)
        guard let (patternValue, runtimeID, consent) = promptForRoute(runtimes) else { return }
        let runtimeValue = runtimeID.rawValue

        var rc = currentRuntimeConfig ?? KinhinConfig.RuntimeConfig()
        guard !rc.routes.contains(where: { $0.pattern == patternValue }) else {
            presentError(
                NSError(
                    domain: "kinhin", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "A route for '\(patternValue)' already exists."]))
            return
        }
        rc.routes.append(
            KinhinConfig.RuntimeConfig.Route(
                pattern: patternValue, runtime: runtimeValue, consent: runtimeID == .host && consent ? true : nil))

        do {
            try RuntimesConfigEditor.apply(rc, to: configURL)
            reload()
            onEdited?()
        } catch {
            presentError(error)
        }
    }

    @objc func removeRouteClicked(_ sender: NSButton) {
        guard let pattern = sender.identifier?.rawValue,
            let rc = currentRuntimeConfig
        else { return }
        var updated = rc
        updated.routes.removeAll { $0.pattern == pattern }
        do {
            try RuntimesConfigEditor.apply(updated, to: configURL)
            reload()
            onEdited?()
        } catch {
            presentError(error)
        }
    }
}
