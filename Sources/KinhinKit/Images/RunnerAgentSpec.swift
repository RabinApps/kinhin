import Foundation

// MARK: - Runner agent

/// The runner agent a forge needs installed, as data: how it is named in logs,
/// where its release feed is, how it is baked into each kind of guest and how
/// it is installed on the host. Image bakes, the Linux container baker, the
/// version resolver and the host installer all iterate these instead of
/// switching on the forge.
///
/// Forges that share one agent (Gitea and Forgejo run the same
/// `gitea-runner`) return the same spec, so it is baked once.
struct RunnerAgentSpec: Sendable {
    /// Stable identity; the forges of one family share it.
    let key: String
    /// The forges this agent serves. A stored token for any of them makes the
    /// agent part of the bake.
    let forges: [ForgeID]
    /// Position in bake and install order (lower first).
    let order: Int
    /// What the user holds, for log lines ("GitHub PAT", "Gitea token").
    let credential: String
    /// What gets installed, for log lines ("actions-runner", "the Azure
    /// Pipelines agent").
    let artifact: String
    /// This agent's version inside a resolved version set.
    let version: @Sendable (RunnerVersionResolver.Versions) -> String
    /// The vendor's release feed, or nil when there is none (the version is
    /// pinned and updated deliberately).
    let feed: ReleaseFeed?
    let bake: Bake
    let host: HostAgentSpec

    /// The install script for each kind of guest.
    struct Bake: Sendable {
        /// A tart macOS guest (run as the admin user).
        let macOS: @Sendable (RunnerVersionResolver.Versions) -> String
        /// A tart Linux guest (passwordless sudo).
        let tartLinux: @Sendable (RunnerVersionResolver.Versions) -> String
        /// A Linux container (root) of the given architecture.
        let container: @Sendable (RunnerVersionResolver.Versions, LinuxPlatform) -> String

        func script(for guestOS: GuestOS, _ versions: RunnerVersionResolver.Versions) -> String {
            switch guestOS {
            case .macOS: return macOS(versions)
            case .linux: return tartLinux(versions)
            }
        }
    }

    /// Release-feed lookup facts for the version resolver.
    struct ReleaseFeed: Sendable {
        /// Log and cache label ("GitHub", "Azure Pipelines").
        let name: String
        let url: URL
        /// True when pre-release tags carry a dash ("v4.1.0-beta.1") and must
        /// be skipped.
        var excludesDashes = false

        /// The feed URLs are string literals, so failing to parse one is a
        /// programming error rather than a runtime condition.
        static func literal(_ string: String) -> URL {
            guard let url = URL(string: string) else {
                preconditionFailure("invalid release feed URL literal: \(string)")
            }
            return url
        }
    }

    /// How the agent is installed on the Mac itself (`HostAgentInstaller`).
    struct HostAgentSpec: Sendable {
        /// Always installed (GitHub and Gitea), instead of only when an
        /// account of this forge is configured.
        let required: Bool
        /// Where the install lands, relative to the agent directory.
        let installedPath: String
        /// Whether the installed file must be executable (config.sh only has to exist).
        let mustBeExecutable: Bool
        /// The missing-file wording: "<what> is missing in <agent dir><location>".
        let missingWhat: String
        let missingLocation: String
        /// The short name in "installed … into" lines ("gitea-runner").
        let summaryName: String
        /// The shell that downloads and unpacks the agent into the agent directory.
        let installScript:
            @Sendable (_ versions: RunnerVersionResolver.Versions, _ arm64: Bool, _ agentDir: URL) -> String

        func isInstalled(in agentDir: URL) -> Bool {
            let path = agentDir.appendingPathComponent(installedPath).path
            return mustBeExecutable
                ? FileManager.default.isExecutableFile(atPath: path) : FileManager.default.fileExists(atPath: path)
        }

        func missingMessage(in agentDir: URL) -> String {
            "the download finished but \(missingWhat) is missing in \(agentDir.path)\(missingLocation)"
        }
    }

    /// "GitHub PAT found — baking actions-runner 2.x" and its skip twin: the
    /// two lines every bake logs per agent.
    func foundLine(_ versions: RunnerVersionResolver.Versions) -> String {
        "\(credential) found — baking \(artifact) \(version(versions))"
    }

    var skippedLine: String { "no \(credential) stored — skipping \(artifact) install" }

    /// Every distinct agent, in bake order.
    static let all: [RunnerAgentSpec] = {
        var seen: Set<String> = []
        return ForgeID.allCases.map(\.descriptor.agent).filter { seen.insert($0.key).inserted }
            .sorted { $0.order < $1.order }
    }()
}
