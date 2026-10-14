import E2ESupport
import Foundation
import Testing

/// Guards that keep this suite honest as kinhin grows. They need no VM, container or network, only the binary.
///
/// - Every forge kinhin supports must be listed in `forges` below, as live-tested, gated on real credentials, or
///   waived with a reason. Adding a forge to kinhin fails the build of this suite until someone decides.
/// - Every CLI command must map to a test (or a reason it cannot have one), and no entry may name a command that no
///   longer exists.
@Suite("Coverage guards", .tags(.coverage), .enabled(if: E2E.enabled))
struct CoverageTests {
    enum ForgeStatus: Sendable {
        /// Stood up locally and exercised by `LifecycleTests`.
        case live(String)
        /// Needs real credentials; runs only when the named environment variables are set.
        case gated(String)
        /// Not exercised, with the reason.
        case waived(String)
    }

    static let forges: [String: ForgeStatus] = [
        "gitea": .live("Gitea in Docker (LifecycleTests, FleetBehaviorTests)"),
        "forgejo": .live("Forgejo in Docker (LifecycleTests)"),
        "gitlab": .live("GitLab CE in Docker (LifecycleTests; heavy: KINHIN_E2E_HEAVY=1 or KINHIN_E2E_FORGES=gitlab)"),
        "github": .gated("KINHIN_E2E_GITHUB_TOKEN + KINHIN_E2E_GITHUB_REPO (LifecycleTests, once configured)"),
        "buildkite": .waived("planned, not supported yet; hosted-only, needs a Buildkite org and cluster token"),
        "azuredevops": .waived("planned, not supported yet; needs an organization, agent pool and PAT"),
        "bitbucket": .waived("planned, not supported yet; Bitbucket Cloud only, needs a workspace and token"),
    ]

    /// Command → the test (or reason) that exercises it. Keyed by the words `kinhin help` prints.
    static let commands: [String: String] = [
        "config init": "CLITests.configInit", "config validate": "CLITests.invalidConfigExitsThree",
        "config migrate": "CLITests.configMigrate",
        "config export": "CLITests.configExportAndImport", "config import": "CLITests.configExportAndImport",
        "video init": "VideoTests.initAndList", "video list": "VideoTests.initAndList",
        "video build":
            "VideoTests.buildPreflight (preflight, no container) and VideoTests.buildWithMusic (a real build; needs KINHIN_E2E_VIDEO_IMAGE)",
        "video music search": "VideoTests.search",
        "video music add": "VideoTests.addToTheOnlyVideo (and the license, video and JSON cases)",
        "video music list": "VideoTests.addToTheOnlyVideo",
        "video theme list": "VideoTests.themeScaffold", "video theme new": "VideoTests.themeScaffold",
        "video music preview":
            "waived: plays audio on this Mac (afplay); its download and resolve paths are the same as add",
        "auth set": "CLITests.accountLifecycle (token comes from the environment in e2e builds)",
        "auth add": "CLITests.accountLifecycle", "auth list": "CLITests.accountLifecycle",
        "auth remove": "CLITests.accountLifecycle", "auth status": "CLITests.accountLifecycle",
        "auth clear": "CLITests.accountLifecycle (clears the Keychain; e2e uses the environment token store)",
        "doctor": "CLITests.doctorJSON", "setup status": "CLITests.doctorJSON (same checklist)",
        "setup repair": "waived: installs software on the machine",
        "runtimes": "CLITests.runtimesAndRoutes", "runtimes route add": "CLITests.runtimesAndRoutes",
        "runtimes route remove": "CLITests.runtimesAndRoutes",
        "image prepare": "ImageBaker (every lifecycle lane bakes through it; Tart lanes use --source/--target)",
        "image list": "CLITests.readOnlyInventory",
        "image delete": "ImageBaker.removeAll", "image prune": "waived: deletes the developer's unused images",
        "image digest": "waived: needs a registry round trip",
        "toolchains": "CLITests.readOnlyInventory", "toolchains detect": "CLITests.toolchainDetection",
        "toolchains list-images": "CLITests.readOnlyInventory",
        "toolchains prune": "waived: deletes shared cache entries",
        "toolchains helper": "ToolchainTests.perJobInstall",
        "start": "waived: foreground twin of daemon (same engine; Sandbox.startDaemon covers it)",
        "daemon": "Sandbox.startDaemon (every lane)", "daemon install": "waived: installs a LaunchAgent",
        "daemon uninstall": "waived: removes a LaunchAgent",
        "status": "FeatureTests.readCommandsOnABusyFleet (status --json on a busy fleet)",
        "pause": "FleetBehaviorTests.pauseAndResume",
        "resume": "FleetBehaviorTests.pauseAndResume", "stop": "Daemon.stop (every lane)",
        "logs": "CLITests.logsShowTheFileTailRedacted, FeatureTests.readCommandsOnABusyFleet",
        "watch": "waived: interactive refresh loop",
        "pipeline": "FeatureTests.readCommandsOnABusyFleet (Gitea: job-level detail only; steps need GitHub)",
        "requeue": "FeatureTests.readCommandsOnABusyFleet (refused on Gitea; GitHub-only, runs once that lane exists)",
        "skip": "FeatureTests.readCommandsOnABusyFleet (refused on Gitea; GitHub-only, runs once that lane exists)",
        "heal": "HealingCLITests.noDaemon, HealingTests.diskPressure (and every HealingTests lane)",
        "heal approve": "HealingCLITests.approveAndDismissArguments, HealingTests.autoNone",
        "heal dismiss": "HealingCLITests.approveAndDismissArguments, HealingTests.diskPressure",
        "cleanup": "waived: deletes the developer's VMs, images and cache",
        "bench": "ToolchainTests.installAndRun", "reset": "CLITests.resetConfigScope",
        "workflow test": "CLITests.localWorkflows", "workflow route": "CLITests.localWorkflows",
        "support": "waived: prints donation links", "issue": "waived: opens a GitHub issue",
        "mcp": "CLITests.mcpHandshake", "version": "CLITests.version", "help": "CoverageTests.everyCommandHasHelp",
    ]

    /// The command words in `kinhin help`'s listing: everything before the first placeholder or double space.
    static func helpCommands(_ help: String) -> [String] {
        var found: [String] = []
        for line in help.split(separator: "\n") {
            guard line.hasPrefix("    "), !line.hasPrefix("     ") else { continue }
            let body = line.dropFirst(4)
            guard let name = body.components(separatedBy: "  ").first, !name.isEmpty else { continue }
            // The exit-code table ("0 ok  1 needs attention") is indented the same way; it is not a command.
            if name.first?.isNumber == true { continue }
            var words: [String] = []
            for word in name.split(separator: " ") {
                if word.hasPrefix("<") || word.hasPrefix("[") || word.first?.isUppercase == true { break }
                words.append(String(word))
            }
            // The usage block lists `kinhin`, `kinhin <command>`: not commands.
            if words.first == "kinhin" || words.isEmpty { continue }
            found.append(words.joined(separator: " "))
        }
        return found
    }

    private func help() async throws -> String {
        let sandbox = try Sandbox()
        defer { sandbox.dispose() }
        return try await sandbox.kinhin(["help"]).stdout
    }

    @Test("every CLI command has a test or a stated reason, and the table names no stale commands")
    func everyCommandIsAccountedFor() async throws {
        let commands = Set(Self.helpCommands(try await help()))
        #expect(commands.count >= 40, "parsed too few commands from `kinhin help`: \(commands.sorted())")
        // `setup repair <what>` and `daemon install` list several lines that share a table entry.
        func covered(_ command: String) -> Bool {
            Self.commands[command] != nil || Self.commands.keys.contains { command.hasPrefix($0 + " ") }
        }
        let missing = commands.filter { !covered($0) }.sorted()
        #expect(missing.isEmpty, "commands with no e2e coverage entry: \(missing)")
        let stale = Self.commands.keys.filter { key in
            !commands.contains(key) && !commands.contains { $0.hasPrefix(key + " ") }
        }.sorted()
        #expect(stale.isEmpty, "coverage entries for commands that no longer exist: \(stale)")
    }

    @Test("every command answers --help with exit 0")
    func everyCommandHasHelp() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.dispose() }
        let commands = Set(Self.helpCommands(try await help()))
        for command in commands.sorted() where command != "help" {
            let result = try await sandbox.kinhin(command.split(separator: " ").map(String.init) + ["--help"])
            #expect(result.ok, "`kinhin \(command) --help` exited \(result.status): \(result.output.prefix(200))")
        }
    }

    @Test("every forge kinhin supports is classified")
    func everyForgeIsClassified() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.dispose() }
        // `auth set --help` lists every forge flag: `--github|--gitlab|--gitea|...`.
        let help = try await sandbox.kinhin(["auth", "set", "--help"]).stdout
        let line = try #require(help.split(separator: "\n").first { $0.contains("--github|") }, "\(help)")
        let supported = Set(
            line.split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "--", with: "")
            })
        #expect(supported.count >= 7, "expected every forge in `auth set --help`, got \(supported)")
        let unclassified = supported.subtracting(Self.forges.keys).sorted()
        #expect(unclassified.isEmpty, "forges with no e2e classification: \(unclassified)")
        let stale = Set(Self.forges.keys).subtracting(supported).sorted()
        #expect(stale.isEmpty, "classified forges kinhin no longer supports: \(stale)")
    }

    @Test("every runtime kinhin can route to has a lane, and every lane names a runtime kinhin has")
    func everyRuntimeHasALane() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.dispose() }
        // "<runtime> is tart, appleContainer, docker or host." (the help text may wrap the list across lines)
        let help = try await sandbox.kinhin(["runtimes", "route", "add", "--help"]).stdout
            .replacingOccurrences(of: "\n", with: " ")
        let sentence = try #require(help.range(of: "<runtime> is ").map { help[$0.upperBound...] }, "\(help)")
        let list = sentence.prefix { $0 != "." }
        let supported = Set(
            list.replacingOccurrences(of: " or ", with: ", ").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        #expect(supported.count >= 4, "parsed too few runtimes: \(supported)")
        let lanes = Set(RuntimeKind.allCases.map(\.kinhinRuntime))
        #expect(supported.subtracting(lanes).isEmpty, "runtimes with no e2e lane: \(supported.subtracting(lanes))")
        #expect(
            lanes.subtracting(supported).isEmpty, "lanes for runtimes kinhin lacks: \(lanes.subtracting(supported))")
        // Tart runs two guest OSes, built and labelled differently: both need a lane.
        #expect(RuntimeKind.allCases.filter(\.isTart).count == 2)
    }

    @Test("every fixture is classified live or gated, and every live or gated forge has a fixture")
    func fixturesMatchTheClassification() {
        var fixtured = Set<String>()
        for kind in ForgeKind.allCases {
            fixtured.insert(kind.rawValue)
            switch Self.forges[kind.rawValue] {
            case .live?, .gated?: break
            default: Issue.record("\(kind) has a fixture but is not classified live or gated")
            }
        }
        for (name, status) in Self.forges {
            switch status {
            case .live, .gated: #expect(fixtured.contains(name), "\(name) is \(status) but has no fixture")
            case .waived: break
            }
        }
    }
}
