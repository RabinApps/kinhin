import Foundation

/// One catalog tool or stack on one platform, resolved the way `image
/// prepare` resolves a single-entry `toolchains:` section.
struct ToolchainBenchPlan: Sendable {
    let id: String
    let isStack: Bool
    let platform: ToolchainPlatform
    /// How the entry installs on this platform ("mise node@22", "brew cask dotnet-sdk", "stack: brew+npm").
    let installer: String
    let category: ToolchainCategory
    /// Tool ids that must be on the guest first (installed untimed when absent).
    let requires: [String]
    let selection: ManagedToolchainSelection
    /// mise tools a macOS guest needs ahead of this entry (untimed): gems must not build against the system Ruby.
    var guestMiseTools: [String] = []
    /// apt packages the guest needs before this entry can build or run (Linux only; installed untimed).
    var guestPackages: [String] = []
    let verify: String
    let workload: ToolchainWorkload

    /// The managed-toolchains install script, with the shared cache mount disabled: the cold path a fresh image pays.
    func installScript(runsAsRoot: Bool) -> String {
        switch platform {
        case .macOS:
            return RunnerBootstrap.managedToolchainsInstallScript(selection: selection, mountPath: nil)
        case .linux:
            return RunnerBootstrap.linuxManagedToolchainsInstallScript(
                selection: selection, mountPath: nil, runsAsRoot: runsAsRoot)
        }
    }

    // MARK: - Resolution

    /// Every catalog tool and stack that claims `platform`, optionally narrowed to `ids`, requirements first.
    static func plans(platform: ToolchainPlatform, ids: [String]? = nil) -> [ToolchainBenchPlan] {
        var plans: [ToolchainBenchPlan] = []
        for tool in ToolchainCatalog.tools where tool.platforms.contains(platform) {
            guard ids == nil || ids?.contains(tool.id) == true else { continue }
            plans.append(plan(for: tool, platform: platform))
        }
        for stack in ToolchainCatalog.stacks where stack.platforms.contains(platform) {
            guard ids == nil || ids?.contains(stack.id) == true else { continue }
            plans.append(plan(for: stack, platform: platform))
        }
        return plans.sorted { ($0.requires.isEmpty ? 0 : 1) < ($1.requires.isEmpty ? 0 : 1) }
    }

    static func plan(for tool: ToolchainEntry, platform: ToolchainPlatform) -> ToolchainBenchPlan {
        let selection = ToolchainCatalog.selection(from: .init(specs: [tool.id]), platform: platform)
        var requires = tool.requires.map(\.toolID)
        // mise installs Elixir without an Erlang on Linux; it is a prerequisite there, not part of the timing.
        if platform == .linux, tool.id == "elixir" { requires.append("erlang") }
        return ToolchainBenchPlan(
            id: tool.id, isStack: false, platform: platform, installer: describe(tool.installer(for: platform), tool),
            category: tool.category, requires: requires, selection: selection,
            guestMiseTools: platform == .macOS && tool.installer(for: .macOS) == .gem(name: tool.id) ? ["ruby"] : [],
            guestPackages: platform == .linux ? linuxGuestPackages[tool.id] ?? [] : [],
            verify: tool.verify,
            workload: ToolchainWorkloads.workload(for: tool.id) ?? .skip(reason: "no workload defined"))
    }

    static func plan(for stack: ToolchainStack, platform: ToolchainPlatform) -> ToolchainBenchPlan {
        // `mountPath` only decides whether the macOS recipe emits its version-pinned SDK steps (fvm install): a cold
        // bench has no cache share, but the SDK must still be installed for the stack to verify.
        let selection = ToolchainCatalog.selection(
            from: .init(stacks: [stack.id]), platform: platform, mountPath: platform == .macOS ? "/unused" : nil)
        let verify =
            platform == .linux && !stack.linuxSteps.isEmpty ? (stack.linuxVerify ?? stack.verify) : stack.verify
        return ToolchainBenchPlan(
            id: stack.id, isStack: true, platform: platform, installer: describe(stack, selection),
            category: category(of: stack), requires: stack.requires.map(\.toolID), selection: selection,
            verify: verify, workload: ToolchainWorkloads.workload(for: stack.id) ?? .skip(reason: "no workload defined")
        )
    }

    /// What a Linux base image lacks that an entry's install or workload needs: a C toolchain to build Lua, to link
    /// Rust, to compile CMake's test project.
    /// Stands for the newest `libpython3.N` the guest's apt offers (it differs per base image).
    static let libpythonToken = "libpython3"

    static let linuxGuestPackages: [String: [String]] = [
        "lua": ["build-essential", "libreadline-dev"],
        "rust": ["build-essential"],
        "cmake": ["build-essential"],
        "gcloud": ["python3", "python-is-python3"],
        // The Swift toolchain links libedit, ncurses, sqlite, libxml2 and the base image's own Python library.
        "swift": [
            "libedit2", "build-essential", "libncurses6", "libsqlite3-0", "libxml2", "libcurl4", "tzdata",
            libpythonToken,
        ],
    ]

    /// Stacks carry no category of their own; they group with what they are made of.
    static func category(of stack: ToolchainStack) -> ToolchainCategory {
        switch stack.id {
        case "flutter": return .languages
        case "react-native": return .build
        default: return .javascript
        }
    }

    private static func describe(_ installer: ToolchainEntry.Installer, _ tool: ToolchainEntry) -> String {
        switch installer {
        case .mise: return "mise \(tool.defaultSpec.isEmpty ? tool.id : tool.defaultSpec)"
        case .brew(let formula, let isCask): return "brew \(isCask ? "cask " : "")\(formula)"
        case .npm(let package): return "npm \(package)"
        case .gem(let name): return "gem \(name)"
        case .apt(let packages): return "apt \(packages.joined(separator: " "))"
        }
    }

    private static func describe(_ stack: ToolchainStack, _ selection: ManagedToolchainSelection) -> String {
        var pieces: [String] = []
        if !selection.brewFormulas.isEmpty { pieces.append("brew") }
        if !selection.aptPackages.isEmpty { pieces.append("apt") }
        if !selection.miseSpecs.isEmpty { pieces.append("mise") }
        if !selection.npmPackages.isEmpty { pieces.append("npm") }
        if !selection.stackSteps.isEmpty { pieces.append("steps") }
        return "stack: " + (pieces.isEmpty ? "none" : pieces.joined(separator: "+"))
    }
}
