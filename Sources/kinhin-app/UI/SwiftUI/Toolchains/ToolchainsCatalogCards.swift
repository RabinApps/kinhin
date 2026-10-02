import KinhinKit
import SwiftUI

/// The "Available toolchains" browser and the "Examples" card: read-only,
/// every entry copyable.
struct ToolchainsCatalogCards: View {
    let model: ToolchainsModel

    var body: some View {
        ForEach(ToolchainCategory.allCases, id: \.rawValue) { category in
            CollapsibleFormCard(title: "Available: " + category.title) {
                ForEach(ToolchainsCatalogListing.tools(in: category)) { item in itemRow(item, prefix: "tool") }
            }
        }
        CollapsibleFormCard(
            title: "Available: Stacks", subtitle: "Bundled recipes: several tools installed together."
        ) {
            ForEach(ToolchainsCatalogListing.stacks) { item in itemRow(item, prefix: "stack") }
        }
        examplesCard
    }

    private func itemRow(_ item: CatalogListingItem, prefix: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(item.id).font(.system(size: 12, weight: .semibold)).textSelection(.enabled)
                Spacer(minLength: 0)
                Text(item.platforms).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(item.defaultVersion)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                copyButton(item.copyText, id: "\(prefix):\(item.id)", label: "Copy \(item.id)")
            }
            HintText(item.summary)
            if let requirement = item.requirement { HintText(requirement) }
        }
    }

    private var examplesCard: some View {
        CollapsibleFormCard(
            title: "Examples", subtitle: "Copy into a .kinhin.yml at the root of a repo (or into config.yaml)."
        ) {
            ForEach(ToolchainsCatalogListing.examples) { example in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(example.title).font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                        copyButton(example.yaml, id: "example:\(example.title)", label: "Copy \(example.title)")
                    }
                    HintText(example.note)
                    Text(example.yaml)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Divider()
            Text("How images bake").font(.system(size: 12, weight: .semibold))
            HintText(ToolchainsCatalogListing.howItWorks)
            HintText(ToolchainsCatalogListing.platformNotes)
        }
    }

    private func copyButton(_ text: String, id: String, label: String) -> some View {
        Button(model.copiedID == id ? "Copied" : "Copy") { model.copy(text, id: id) }
            .controlSize(.small)
            .accessibilityLabel(label)
            .accessibilityIdentifier("copy:\(id)")
    }
}
