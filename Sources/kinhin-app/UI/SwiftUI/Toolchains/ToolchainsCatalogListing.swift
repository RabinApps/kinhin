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

/// A copyable `.kinhin.yml` snippet with a one-line note.
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
            ? "macOS · Linux" : (set.contains(.macOS) ? "macOS only" : "Linux only")
    }

    private static func requirementText(_ requires: [ToolchainRequirement]) -> String? {
        requires.isEmpty
            ? nil
            : "needs " + requires.map(\.example).joined(separator: ", ") + " in specs (never installed implicitly)"
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
                defaultVersion: versionable ? (version ?? "latest") : "no @version",
                platforms: platformLabel(entry.platforms), requirement: requirementText(entry.requires),
                copyText: entry.defaultSpec.isEmpty ? entry.id : entry.defaultSpec)
        }
    }

    static var stacks: [CatalogListingItem] {
        ToolchainCatalog.stacks.map { stack in
            CatalogListingItem(
                id: stack.id, summary: stack.summary,
                defaultVersion: stack.versionKind == nil
                    ? "no @version" : (stack.defaultVersion.isEmpty ? "latest" : stack.defaultVersion),
                platforms: platformLabel(stack.platforms), requirement: requirementText(stack.requires),
                copyText: stack.id)
        }
    }

    // MARK: - Examples

    /// Every snippet satisfies the no-implicit-installs rule: node, java and
    /// dotnet are listed in `specs` wherever a tool or stack needs them.
    static let examples: [ToolchainExample] = [
        ToolchainExample(
            title: "Go + Node",
            note: "Two pinned languages. Repos that resolve to the same set share one image.",
            yaml: """
                toolchains:
                  specs: [go@1.22.5, node@20]
                """),
        ToolchainExample(
            title: "Web app with pnpm and Playwright",
            note: "pnpm and Playwright need Node, so node is listed too.",
            yaml: """
                toolchains:
                  specs: [node@22, pnpm, playwright]
                """),
        ToolchainExample(
            title: "Flutter stack",
            note: "macOS and Linux. The version after @ is the Flutter SDK version.",
            yaml: """
                toolchains:
                  stacks: [flutter@3.24.0]
                """),
        ToolchainExample(
            title: "Expo (React Native with Node)",
            note: "The expo stack needs Node, so node is in specs.",
            yaml: """
                toolchains:
                  specs: [node@22]
                  stacks: [expo]
                """),
        ToolchainExample(
            title: "JVM with Gradle",
            note: "gradle needs a JDK, so java is listed too.",
            yaml: """
                toolchains:
                  specs: [java@temurin-21, gradle]
                """),
    ]

    /// Notes shown with the examples: platform differences and when images bake.
    static let platformNotes =
        "macOS-only entries (for example react-native) are skipped in Linux images. Tools without @version (php, dotnet, yamllint, composer) install the platform's current release."

    static let howItWorks =
        "Each project's toolchains are baked once into an image cloned from the base image, so identical sets across repos share an image. A queued job resolves its set from the repo's .kinhin.yml at the job's branch or tag (only when the project entry has repo_file: true), then the project entry's own toolchains. Repos with neither get the plain base image and can still run kinhin-toolchain install per job. If the image is not baked yet, the bake starts in the background and the job runs on the base image meanwhile; later jobs use the baked image. Fork pull requests never use the repo's own file. Derived images that go unused, or exceed the image limit, are pruned."
}
