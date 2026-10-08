import KinhinKit
import SwiftUI

/// The Toolchains tab: a read-only view of how each repo resolves its
/// toolchains, a catalog browser, copyable `.kinhin.yml` examples, and the
/// base image status. Nothing here edits toolchains.
struct ToolchainsView: View {
    let model: ToolchainsModel
    /// Leading/trailing inset around the cards and footer.
    var inset: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ToolchainsGuideView()
                    reposCard
                    if !model.repoFileImages.isEmpty { derivedImagesCard }
                    ToolchainsCatalogCards(model: model)
                    imagesCard
                }
                .padding(.horizontal, inset)
                .padding(.top, 4)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
    }

    // MARK: - Repos

    private var reposCard: some View {
        FormCard(
            title: "Repos",
            subtitle: "One row per project in config.yaml, then everything else."
        ) {
            if model.rows.isEmpty {
                HintText("config.yaml could not be read; see the message below.")
            }
            ForEach(model.rows) { row in
                repoRow(row)
                if row.id != model.rows.last?.id { Divider() }
            }
        }
    }

    private func repoRow(_ row: ProjectToolchainsRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(row.isDefault ? "Other repos" : row.pattern)
                    .font(.system(size: 12, weight: .semibold))
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Text(ToolchainsModel.sourceTitle(row)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HintText(ToolchainsModel.detail(row))
            if row.hasToolchains {
                chipRow(label: "Tools", items: row.specs)
                chipRow(label: "Homebrew", items: row.brew)
                chipRow(label: "Stacks", items: row.stacks)
            }
            if let base = row.baseImage {
                imageText("Base image: " + model.baseImageLine(base))
            }
            ForEach(row.images) { record in imageText("Derived image: " + model.imageLine(record)) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("repo:\(row.id)")
    }

    @ViewBuilder
    private func chipRow(label: String, items: [String]) -> some View {
        if !items.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                Text(items.joined(separator: "   "))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func imageText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var derivedImagesCard: some View {
        FormCard(
            title: "Images from .kinhin.yml files",
            subtitle:
                "Derived images that no fixed toolchain list accounts for. Their versions came from repo files at job time."
        ) {
            ForEach(model.repoFileImages) { record in
                VStack(alignment: .leading, spacing: 1) {
                    imageText(model.imageLine(record))
                    HintText(record.summary)
                }
            }
        }
    }

    // MARK: - Base image

    /// One row per runtime that is set up: its base image (read-only) and a
    /// rebuild of the base image. Rebuilding does not change any toolchain.
    private var imagesCard: some View {
        FormCard(
            title: "Base images",
            subtitle: "The image every job starts from. Per-repo images with toolchains are cloned from it."
        ) {
            if model.imageRuntimes.isEmpty {
                HintText("No runtime is set up yet. Set one up in Advanced → Capacity.")
            }
            ForEach(model.imageRuntimes, id: \.runtime) { item in
                imageRow(item)
            }
        }
    }

    private func imageRow(_ item: ToolchainsModel.ImageRuntime) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(ToolchainsModel.runtimeTitle(item.runtime)).font(.system(size: 12, weight: .semibold))
                if item.runtime != .tart {
                    HintText("Base image: " + (model.baseImage(for: item.runtime) ?? "default"))
                }
            }
            Spacer(minLength: 0)
            Button("Rebuild base image…") { model.startRebuild(item.runtime) }
                .controlSize(.small)
                .disabled(!model.rebuildEnabled)
                .accessibilityIdentifier("rebuild:\(item.runtime.rawValue)")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Working") }
            StatusText(text: model.status.text, style: model.status.style)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if model.busy {
                Button("Cancel") { model.cancelRunning() }
                    .controlSize(.small)
                    .accessibilityIdentifier("toolchains-busy-cancel")
            }
        }
        .padding(.leading, inset)
        .frame(width: FormMetrics.width, alignment: .leading)
    }
}
