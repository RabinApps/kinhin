import AppKit
import SwiftUI

/// The Accounts page: the Connect form the wizard uses, filling its column, with the load-error banner on top when
/// config.yaml can't be read. The This Mac form lives with the VM settings under Runtimes.
struct AccountsSectionView: View {
    let connect: ConnectModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                HintText("Where kinhin picks up jobs. Tokens live in your Keychain, never in a file.")
                if let loadError = connect.accounts.loadError {
                    Banner(verbatim: loadError.text, kind: .error)
                        .action("Open config") { NSWorkspace.shared.open(connect.accounts.configURL) }
                        .accessibilityIdentifier("accounts-load-error")
                }
                ConnectView(model: connect, layout: .fill)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Spacing.md)
        }
    }
}
