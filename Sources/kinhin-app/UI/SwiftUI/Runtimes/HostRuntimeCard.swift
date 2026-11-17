import KinhinKit
import SwiftUI

/// The Host (this Mac) card: no switch, no settings. The host runtime serves only the routes that name it, each with
/// its own consent, so the card says what it is and why it is flagged.
struct HostRuntimeCard: View {
    @Bindable var runtimes: RuntimesModel
    let mac: MacToolsModel

    var body: some View {
        RuntimeCard(
            runtime: .host, runtimes: runtimes, mac: mac,
            detail: Text("Runs jobs directly on your Mac, no isolation. Used only by routes you add.")
        ) { _ in
            Text("No enable switch — add a route to a repo you trust. Each Host route needs explicit consent.")
                .typeStyle(.body)
                .foregroundStyle(.secondary)
        }
    }
}
