import KinhinKit
import SwiftUI

// The pages of the sections that are still thin adapters over the per-domain views. A later pass redesigns each from
// `design/kinhin-app.fig`; until then these only host what exists.

/// A page heading (display type) over its content, which fills the rest of the page.
struct PageHeaderStack<Content: View, Trailing: View>: View {
    let title: String
    let trailing: Trailing
    let content: Content

    init(title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .center) {
                Text(verbatim: title)
                    .typeStyle(.display)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Spacing.md)
                trailing
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension PageHeaderStack where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

// MARK: - Runtimes

/// Runtimes: capacity (This Mac, reserve, the split between runtimes, VM size) then routing (pools, routes, labels),
/// stacked in one scroll.
struct RuntimesPage: View {
    let capacity: CapacityModel
    let mac: MacToolsModel
    let runtimes: RuntimesModel

    var body: some View {
        PageHeaderStack(title: MainSection.runtimes.label) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    CapacityView(model: capacity, mac: mac, runtimes: runtimes, embedded: true)
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        SectionHeader("Routing")
                        RuntimesView(model: runtimes, embedded: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Spacing.md)
            }
        }
    }
}
