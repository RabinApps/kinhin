import KinhinKit
import SwiftUI

/// The "Available toolchains" browser and the "Examples" card: read-only,
/// every entry copyable.
struct ToolchainsCatalogCards: View {
    let model: ToolchainsModel

    var body: some View {
        ForEach(ToolchainCategory.allCases, id: \.rawValue) { category in
            CollapsibleFormCard(
                title: Text(
                    verbatim: String(
                        localized: "Available: \(category.title)", bundle: .l10n,
                        comment: "Card title in the toolchains catalog; %@ is a category such as Languages")),
                layout: .fill
            ) {
                ForEach(ToolchainsCatalogListing.tools(in: category)) { item in itemRow(item, prefix: "tool") }
            }
        }
        CollapsibleFormCard(
            title: "Available: Stacks", subtitle: "Bundled recipes: several tools installed together.", layout: .fill
        ) {
            ForEach(ToolchainsCatalogListing.stacks) { item in itemRow(item, prefix: "stack") }
        }
        examplesCard
    }

    private func itemRow(_ item: CatalogListingItem, prefix: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.sm) {
                Text(item.id).typeStyle(.emphasis).textSelection(.enabled)
                Spacer(minLength: 0)
                Text(item.platforms).typeStyle(.caption).foregroundStyle(.secondary)
                Text(item.defaultVersion)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                copyButton(
                    item.copyText, id: "\(prefix):\(item.id)",
                    label: String(
                        localized: "Copy \(item.id)", bundle: .l10n,
                        comment: "VoiceOver label of a Copy button; %@ is a tool id"))
            }
            HintText(verbatim: item.summary)
            if let requirement = item.requirement { HintText(verbatim: requirement) }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(Palette.grouped))
    }

    private var examplesCard: some View {
        CollapsibleFormCard(
            title: "Examples", subtitle: "Copy into .kinhin/config.yml in a repo (or into config.yaml).",
            layout: .fill
        ) {
            ForEach(ToolchainsCatalogListing.examples) { example in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        Text(example.title).typeStyle(.emphasis)
                        Spacer(minLength: 0)
                        copyButton(
                            example.yaml, id: "example:\(example.title)",
                            label: String(
                                localized: "Copy \(example.title)", bundle: .l10n,
                                comment: "VoiceOver label of a Copy button; %@ is an example title"))
                    }
                    HintText(verbatim: example.note)
                    YAMLSnippet(yaml: example.yaml)
                }
            }
            Divider()
            Text("How images bake").typeStyle(.emphasis)
            HintText(verbatim: ToolchainsCatalogListing.howItWorks)
            HintText(verbatim: ToolchainsCatalogListing.platformNotes)
        }
    }

    private func copyButton(_ text: String, id: String, label: String) -> some View {
        Button(model.copiedID == id ? "Copied" : "Copy") { model.copy(text, id: id) }
            .controlSize(.small)
            .accessibilityLabel(label)
            .accessibilityIdentifier("copy:\(id)")
    }
}
