import AppKit
import SwiftUI

/// The "every repo needs its own toolchains" explainer, shared by the setup
/// wizard's Toolchains step and the top of Advanced → Toolchains. It holds no
/// state that matters and never writes config.
struct ToolchainsGuideView: View {
    /// Puts text on the clipboard. Injectable for previews.
    var copy: (String) -> Void = ToolchainsGuide.copyToPasteboard
    @State private var copiedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ToolchainsGuide.intro)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(ToolchainsGuide.examples) { example in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(example.title).font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                        Button(copiedID == example.id ? "Copied" : "Copy") {
                            copy(example.yaml)
                            copiedID = example.id
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Copy \(example.title)")
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
            HintText(ToolchainsGuide.noToolchainsNote)
            if let url = ToolchainsGuide.docsURL {
                Link("Read the docs: per-project toolchains", destination: url).font(.system(size: 12))
            }
        }
        .frame(width: FormMetrics.width, alignment: .leading)
    }
}

/// Wording and examples for `ToolchainsGuideView`.
enum ToolchainsGuide {
    /// The guide's "Per-project toolchains" section, as rendered by GitHub.
    static let docsURL = URL(
        string: "https://github.com/RabinApps/kinhin/blob/main/docs/toolchains.md#per-project-toolchains")

    static let intro =
        "Every repo needs its own toolchains, and nothing is chosen in this app. Declare them in the repo's .kinhin.yml (enabled by a projects: entry with repo_file: true in config.yaml), or list them directly under projects[].toolchains in config.yaml."

    static let noToolchainsNote =
        "Repos with neither get the plain base image, with no toolchains baked in. Their jobs can still run `kinhin-toolchain install` per job."

    struct Example: Identifiable, Equatable {
        var id: String { title }
        var title: String
        var note: String
        var yaml: String
    }

    static let examples: [Example] = [
        Example(
            title: "In the repo: .kinhin.yml",
            note: "Commit this at the repo root, then enable it in config.yaml with the second snippet.",
            yaml: """
                toolchains:
                  specs: [go@1.22.5, node@20]
                """),
        Example(
            title: "In config.yaml: honor the repo file",
            note: "Off by default: a repo file chooses what is installed on this Mac.",
            yaml: """
                projects:
                  - pattern: "acme/api"
                    repo_file: true
                """),
        Example(
            title: "In config.yaml: toolchains listed directly",
            note: "No repo file needed. These versions apply to every matching repo.",
            yaml: """
                projects:
                  - pattern: "acme/api"
                    toolchains:
                      specs: [go@1.22.5, node@20]
                """),
    ]

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
