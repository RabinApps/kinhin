import AppKit
import KinhinKit
import SwiftUI

// The Fleet tab (see `FleetView`): the window controller feeds it statuses and
// routes its buttons to the delegate and the sheets.
@MainActor
extension MainTabsWindowController {
    func buildFleetTab() -> NSView {
        let host = NSHostingView(rootView: FleetView(model: fleetModel))
        // Fills whatever it is pinned into.
        host.sizingOptions = []
        return host
    }

    /// Re-renders the Fleet tab from a fresh status. Safe to call before the
    /// tab exists or the first refresh.
    func render(status: FleetStatus?) {
        fleetModel.status = status
    }

    @objc func logsClicked() { delegate?.openLogsFolder() }
}
