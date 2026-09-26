import SwiftUI

/// Advanced → Accounts: the same Connect and This Mac forms the wizard uses,
/// stacked in one scrolling page for changing them after setup.
struct AccountsSectionView: View {
    let connect: ConnectModel
    let mac: MacToolsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Connect")
                ConnectView(model: connect)
                SectionHeader("This Mac")
                MacToolsView(model: mac)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
    }
}
