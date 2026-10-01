import AppKit
import KinhinKit
import SwiftUI

// The Fleet tab (see `FleetView`): `FleetModel` reads the shared
// `FleetController`; the window controller routes its buttons to the delegate and the sheets.
@MainActor
extension MainTabsWindowController {
    func buildFleetTab() -> NSView {
        let host = NSHostingView(rootView: FleetView(model: fleetModel))
        // Fills whatever it is pinned into.
        host.sizingOptions = []
        return host
    }

    @objc func logsClicked() { delegate?.openLogsFolder() }
}
