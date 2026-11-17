import KinhinKit
import SwiftUI

/// The Toolchains page: a read-only view of how each repo resolves its
/// toolchains, a catalog browser, copyable `.kinhin/config.yml` examples, and the
/// base image status. Nothing here edits toolchains.
struct ToolchainsView: View {
    let model: ToolchainsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                HintText("What every runner image has installed.")
                ToolchainsGuideCard()
                reposCard
                if !model.repoFileImages.isEmpty { derivedImagesCard }
                imagesCard
                ToolchainsCatalogCards(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Spacing.md)
        }
    }

    // MARK: - Repos

    private var reposCard: some View {
        Card(
            title: "Repos",
            subtitle: "One row per project in config.yaml, then everything else.", layout: .fill
        ) {
            if model.rows.isEmpty {
                StatusText(text: "config.yaml could not be read; see the message below.", style: .error)
            }
            ForEach(model.rows) { row in
                repoRow(row)
            }
        }
    }

    private func repoRow(_ row: ProjectToolchainsRow) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Text(row.isDefault ? "Other repos" : row.pattern)
                    .typeStyle(.emphasis)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Text(ToolchainsModel.sourceTitle(row)).typeStyle(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            HintText(verbatim: ToolchainsModel.detail(row))
            if row.hasToolchains {
                chipRow(label: "Tools", items: row.specs)
                chipRow(label: "Homebrew", items: row.brew)
                chipRow(label: "Stacks", items: row.stacks)
            }
            if let base = row.baseImage {
                imageText(
                    String(
                        localized: "Base image: \(model.baseImageLine(base))", bundle: .l10n,
                        comment: "Toolchains tab row; %@ is an image name and size"))
            }
            ForEach(row.images) { record in
                imageText(
                    String(
                        localized: "Derived image: \(model.imageLine(record))", bundle: .l10n,
                        comment: "Toolchains tab row; %@ is an image name, size and last use"))
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(Palette.grouped))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("repo:\(row.id)")
    }

    @ViewBuilder
    private func chipRow(label: LocalizedStringKey, items: [String]) -> some View {
        if !items.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(label).typeStyle(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                ForEach(items, id: \.self) { item in Chip(verbatim: item, tone: .neutral) }
            }
        }
    }

    private func imageText(_ text: String) -> some View {
        Text(verbatim: text)
            .typeStyle(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var derivedImagesCard: some View {
        Card(
            title: "Images from .kinhin/config.yml files",
            subtitle:
                "Derived images that no fixed toolchain list accounts for. Their versions came from repo files at job time.",
            layout: .fill
        ) {
            ForEach(model.repoFileImages) { record in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(verbatim: model.imageLine(record)).typeStyle(.emphasis).textSelection(.enabled)
                    HintText(verbatim: record.summary)
                }
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.lg).fill(Palette.grouped))
            }
        }
    }

    // MARK: - Base image

    /// One row per runtime that is set up: its base image (read-only) and a
    /// rebuild of the base image. Rebuilding does not change any toolchain.
    private var imagesCard: some View {
        Card(
            title: "Base images",
            subtitle: "The image every job starts from. Per-repo images with toolchains are cloned from it.",
            layout: .fill
        ) {
            if model.imageRuntimes.isEmpty {
                HintText("No runtime is set up yet. Set one up in Runtimes.")
            }
            ForEach(model.imageRuntimes, id: \.runtime) { item in
                imageRow(item)
            }
            progress
        }
    }

    private func imageRow(_ item: ToolchainsModel.ImageRuntime) -> some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(ToolchainsModel.runtimeTitle(item.runtime)).typeStyle(.emphasis)
                if item.runtime != .tart {
                    HintText(
                        verbatim: String(
                            localized:
                                "Base image: \(model.baseImage(for: item.runtime) ?? String(localized: "default", bundle: .l10n, comment: "Shown as the base image when none is configured"))",
                            bundle: .l10n, comment: "Toolchains tab row; %@ is an image name or the word default"))
                }
            }
            Spacer(minLength: 0)
            Button("Rebuild base image…") { _ = model.startRebuild(item.runtime) }
                .controlSize(.small)
                .disabled(!model.rebuildEnabled)
                .accessibilityIdentifier("rebuild:\(item.runtime.rawValue)")
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(Palette.grouped))
    }

    /// The progress line: spinner and Cancel while a rebuild runs, then the result.
    private var progress: some View {
        HStack(spacing: Spacing.sm) {
            if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Working") }
            StatusText(verbatim: model.status.text, style: model.status.style)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if model.busy {
                Button("Cancel") { model.cancelRunning() }
                    .controlSize(.small)
                    .accessibilityIdentifier("toolchains-busy-cancel")
            }
        }
    }
}
