import SwiftUI

/// Advanced → Accounts: the Connect form the wizard uses, as a page for
/// changing forges after setup. The This Mac form it used to stack lives with
/// the VM settings under Advanced → Capacity.
struct AccountsSectionView: View {
    let connect: ConnectModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Connect")
                ConnectView(model: connect)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
    }
}
