import KinhinKit
import SwiftUI

/// The Toolchains form: tool, stack, and extras cards, the image-rebuild
/// card, and an Apply / Revert footer.
struct ToolchainsView: View {
    let model: ToolchainsModel
    /// Whether Return triggers Apply. The wizard turns this off so Return
    /// stays bound to its Continue button.
    var appliesOnReturn = true
    /// Leading/trailing inset around the cards and footer.
    var inset: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HintText(
                        "Pick what your jobs need preinstalled. Changes take effect when you rebuild an image below."
                    )
                    .frame(width: FormMetrics.width, alignment: .leading)
                    HintText(
                        "Every row shows its platform note: “macOS · Linux” applies to both, “macOS only” skips on Linux, “Linux only” skips on macOS. Version fields pin a specific version (e.g. node@22)."
                    )
                    .frame(width: FormMetrics.width, alignment: .leading)
                    ForEach(toolGroups, id: \.title) { group in
                        toolsCard(group.title, group.entries)
                    }
                    stacksCard
                    extrasCard
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

    // MARK: Tool cards

    private var toolGroups: [(title: String, entries: [ToolchainEntry])] {
        ToolchainCategory.allCases.map { category in
            (category.title, ToolchainCatalog.tools.filter { $0.category == category })
        }
    }

    private func platformLabel(_ platforms: [ToolchainPlatform]) -> String {
        let set = Set(platforms)
        return set.contains(.macOS) && set.contains(.linux)
            ? "macOS · Linux" : (set.contains(.macOS) ? "macOS only" : "Linux only")
    }

    private func toolsCard(_ title: String, _ entries: [ToolchainEntry]) -> some View {
        FormCard(title: title) {
            ForEach(entries, id: \.id) { entry in
                entryRow(
                    id: entry.id, tag: platformLabel(entry.platforms),
                    isOn: Binding(get: { model.isToolOn(entry.id) }, set: { model.setTool(entry.id, on: $0) }),
                    text: Binding(get: { model.toolText[entry.id] ?? "" }, set: { model.setToolText(entry.id, $0) }),
                    placeholder: model.toolPlaceholder(entry), fieldEnabled: model.toolFieldEnabled(entry),
                    versionLabel: "\(entry.id) version", idPrefix: "tool", summary: entry.summary)
            }
        }
    }

    private var stacksCard: some View {
        FormCard(title: "Stacks", subtitle: "Bundled recipes: several tools installed together.") {
            ForEach(ToolchainCatalog.stacks, id: \.id) { stack in
                entryRow(
                    id: stack.id, tag: platformLabel(stack.platforms),
                    isOn: Binding(get: { model.isStackOn(stack.id) }, set: { model.setStack(stack.id, on: $0) }),
                    text: Binding(get: { model.stackText[stack.id] ?? "" }, set: { model.setStackText(stack.id, $0) }),
                    placeholder: model.stackPlaceholder(stack), fieldEnabled: model.stackFieldEnabled(stack),
                    versionLabel: "\(stack.id) version", idPrefix: "stack", summary: stack.summary)
            }
        }
    }

    /// A checkbox, its platform tag, a version field, and a one-line summary.
    private func entryRow(
        id: String, tag: String, isOn: Binding<Bool>, text: Binding<String>, placeholder: String,
        fieldEnabled: Bool, versionLabel: String, idPrefix: String, summary: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle(id, isOn: isOn)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .accessibilityIdentifier("\(idPrefix):\(id)")
                Spacer(minLength: 0)
                Text(tag).font(.system(size: 10)).foregroundStyle(.secondary)
                // Verbatim prompt: a literal title would be parsed as markdown.
                TextField("", text: text, prompt: Text(verbatim: placeholder))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                    .disabled(!fieldEnabled)
                    .accessibilityIdentifier("\(idPrefix)ver:\(id)")
                    .accessibilityLabel(versionLabel)
            }
            HintText(summary)
        }
    }

    // MARK: Extras

    private var extrasCard: some View {
        FormCard(title: "Other", subtitle: "Anything not in the lists above. Comma-separated.") {
            HStack(spacing: 8) {
                Text("Homebrew").font(.system(size: 12))
                TextField(
                    "", text: Binding(get: { model.brewText }, set: { model.setBrewText($0) }),
                    prompt: Text(verbatim: "wget, cmake")
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .accessibilityIdentifier("extra-brew")
            }
            HintText("Homebrew packages: macOS images only.")
            HStack(spacing: 8) {
                Text("Other tools").font(.system(size: 12))
                TextField(
                    "", text: Binding(get: { model.specsText }, set: { model.setSpecsText($0) }),
                    prompt: Text(verbatim: "zig@0.13")
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .accessibilityIdentifier("extra-specs")
            }
            HintText("Any tool mise can install, as name@version.")
            Toggle(
                "Share the download cache with runners",
                isOn: Binding(get: { model.working.shareCache }, set: { model.setShareCache($0) })
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .accessibilityIdentifier("share-cache")
            HintText("Per-job installs (npm ci, mise install…) reuse downloads instead of fetching them again.")
        }
    }

    // MARK: Images

    /// One row per runtime that is actually set up, saying what its image
    /// will contain and offering a rebuild.
    private var imagesCard: some View {
        FormCard(title: "Rebuild images", subtitle: "Your saved tools are baked in when an image is rebuilt.") {
            if model.imageRuntimes.isEmpty {
                HintText("No runtime is set up yet. Set one up in Advanced → Accounts.")
            }
            ForEach(model.imageRuntimes, id: \.runtime) { item in
                imageRow(item)
            }
        }
    }

    private func imageRow(_ item: ToolchainsModel.ImageRuntime) -> some View {
        let plan = ToolchainsConfigEditor.plan(model.baseline, for: item.platform)
        var detail =
            plan.installing.isEmpty
            ? "No tools selected." : "Installs \(plan.installing.count): \(plan.installing.joined(separator: ", "))"
        if !plan.skipped.isEmpty { detail += " · skips \(plan.skipped.joined(separator: ", "))" }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(ToolchainsModel.runtimeTitle(item.runtime)).font(.system(size: 12, weight: .semibold))
                    HintText(detail)
                }
                Spacer(minLength: 0)
                Button("Rebuild Image…") { model.startRebuild(item.runtime) }
                    .controlSize(.small)
                    .disabled(!model.rebuildEnabled)
                    .accessibilityIdentifier("rebuild:\(item.runtime.rawValue)")
            }
            // Linux images are baked on a base image the user can change.
            if item.runtime != .tart {
                HStack(alignment: .top, spacing: 8) {
                    Text("Base image").font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    BaseImagePickerField(value: model.baseImage(for: item.runtime)) {
                        model.saveBaseImage($0, for: item.runtime)
                    }
                    .fixedSize()
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.small) }
            StatusText(text: model.status.text, style: model.status.style)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button("Revert") { model.revert() }
                .disabled(!model.revertEnabled)
            Button("Apply") { model.apply() }
                .keyboardShortcut(appliesOnReturn ? .defaultAction : nil)
                .disabled(!model.applyEnabled)
                .accessibilityIdentifier("toolchains-apply")
        }
        .padding(.leading, inset)
        .frame(width: FormMetrics.width, alignment: .leading)
    }
}
