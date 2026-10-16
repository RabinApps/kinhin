import KinhinKit

/// One row of the read-only "Available toolchains" browser.
struct CatalogListingItem: Equatable, Identifiable {
    var id: String
    var summary: String
    /// The default version, or a note when the entry has none ("—").
    var defaultVersion: String
    var platforms: String
    /// What must also be in `specs`, e.g. "needs node@22"; nil when nothing.
    var requirement: String?
    /// What the Copy button puts on the clipboard: the spec or stack id.
    var copyText: String
}

/// A copyable `.kinhin/config.yml` snippet with a one-line note.
struct ToolchainExample: Equatable, Identifiable {
    var id: String { title }
    var title: String
    var note: String
    var yaml: String
}

/// Builds the browser and examples from `ToolchainCatalog`, so they cannot
/// drift from what the engine accepts.
enum ToolchainsCatalogListing {
    static func platformLabel(_ platforms: [ToolchainPlatform]) -> String {
        let set = Set(platforms)
        return set.contains(.macOS) && set.contains(.linux)
            ? String(
                localized: "macOS · Linux", bundle: .l10n, comment: "Toolchain catalog: platforms an entry supports")
            : (set.contains(.macOS)
                ? String(
                    localized: "macOS only", bundle: .l10n, comment: "Toolchain catalog: platforms an entry supports")
                : String(
                    localized: "Linux only", bundle: .l10n, comment: "Toolchain catalog: platforms an entry supports"))
    }

    private static func requirementText(_ requires: [ToolchainRequirement]) -> String? {
        requires.isEmpty
            ? nil
            : String(
                localized:
                    "needs \(requires.map(\.example).joined(separator: ", ")) in specs (never installed implicitly)",
                bundle: .l10n, comment: "Toolchain catalog: dependency note; %@ lists spec examples such as node@22")

    }

    static func tools(in category: ToolchainCategory) -> [CatalogListingItem] {
        ToolchainCatalog.tools.filter { $0.category == category }.map { entry in
            let version = entry.defaultSpec.split(separator: "@").dropFirst().first.map(String.init)
            let versionable: Bool
            switch entry.installer {
            case .mise, .npm: versionable = true
            default: versionable = false
            }
            return CatalogListingItem(
                id: entry.id, summary: entry.summary,
                defaultVersion: versionable
                    ? (version
                        ?? String(
                            localized: "latest", bundle: .l10n,
                            comment: "Toolchain catalog: default version is the newest release"))
                    : String(
                        localized: "no @version", bundle: .l10n,
                        comment: "Toolchain catalog: this entry takes no @version suffix; keep @version verbatim"),
                platforms: platformLabel(entry.platforms), requirement: requirementText(entry.requires),
                copyText: entry.defaultSpec.isEmpty ? entry.id : entry.defaultSpec)
        }
    }

    static var stacks: [CatalogListingItem] {
        ToolchainCatalog.stacks.map { stack in
            CatalogListingItem(
                id: stack.id, summary: stack.summary,
                defaultVersion: stack.versionKind == nil
                    ? String(
                        localized: "no @version", bundle: .l10n,
                        comment: "Toolchain catalog: this entry takes no @version suffix; keep @version verbatim")
                    : (stack.defaultVersion.isEmpty
                        ? String(
                            localized: "latest", bundle: .l10n,
                            comment: "Toolchain catalog: default version is the newest release")
                        : stack.defaultVersion),
                platforms: platformLabel(stack.platforms), requirement: requirementText(stack.requires),
                copyText: stack.id)
        }
    }

    // MARK: - Examples

    /// Every snippet satisfies the no-implicit-installs rule: node, java and
    /// dotnet are listed in `specs` wherever a tool or stack needs them.
    static let examples: [ToolchainExample] = [
        ToolchainExample(
            title: String(localized: "Go + Node", bundle: .l10n, comment: "Toolchain example title"),
            note: String(
                localized: "Two pinned languages. Repos that resolve to the same set share one image.", bundle: .l10n,
                comment: "Toolchain example note; names like node, pnpm and java stay verbatim"),
            yaml: """
                toolchains:
                  specs: [go@1.22.5, node@20]
                """),
        ToolchainExample(
            title: String(
                localized: "Web app with pnpm and Playwright", bundle: .l10n, comment: "Toolchain example title"),
            note: String(
                localized: "pnpm and Playwright need Node, so node is listed too.", bundle: .l10n,
                comment: "Toolchain example note; names like node, pnpm and java stay verbatim"),
            yaml: """
                toolchains:
                  specs: [node@22, pnpm, playwright]
                """),
        ToolchainExample(
            title: String(localized: "Flutter stack", bundle: .l10n, comment: "Toolchain example title"),
            note: String(
                localized: "macOS and Linux. The version after @ is the Flutter SDK version.", bundle: .l10n,
                comment: "Toolchain example note; names like node, pnpm and java stay verbatim"),
            yaml: """
                toolchains:
                  stacks: [flutter@3.24.0]
                """),
        ToolchainExample(
            title: String(
                localized: "Expo (React Native with Node)", bundle: .l10n, comment: "Toolchain example title"),
            note: String(
                localized: "The expo stack needs Node, so node is in specs.", bundle: .l10n,
                comment: "Toolchain example note; names like node, pnpm and java stay verbatim"),
            yaml: """
                toolchains:
                  specs: [node@22]
                  stacks: [expo]
                """),
        ToolchainExample(
            title: String(localized: "JVM with Gradle", bundle: .l10n, comment: "Toolchain example title"),
            note: String(
                localized: "gradle needs a JDK, so java is listed too.", bundle: .l10n,
                comment: "Toolchain example note; names like node, pnpm and java stay verbatim"),
            yaml: """
                toolchains:
                  specs: [java@temurin-21, gradle]
                """),
    ]

    /// Notes shown with the examples: platform differences and when images bake.
    static let platformNotes =
        String(
            localized:
                "macOS-only entries (for example react-native) are skipped in Linux images. Tools without @version (php, dotnet, yamllint, composer) install the platform's current release.",
            bundle: .l10n, comment: "Toolchains tab note under the examples; tool names stay verbatim")

    static let howItWorks =
        String(
            localized:
                "Each project's toolchains are baked once into an image cloned from the base image, so identical sets across repos share an image. A queued job resolves its set from the repo's .kinhin/config.yml (or .kinhin.yml) at the job's branch or tag (only when the project entry has repo_file: true), then the project entry's own toolchains. Repos with neither get the plain base image and can still run kinhin-toolchain install per job. If the image is not baked yet, the bake starts in the background and the job runs on the base image meanwhile; later jobs use the baked image. Fork pull requests never use the repo's own file. Derived images that go unused, or exceed the image limit, are pruned.",
            bundle: .l10n, comment: "Toolchains tab explanation of how images bake; file and key names stay verbatim")
}
