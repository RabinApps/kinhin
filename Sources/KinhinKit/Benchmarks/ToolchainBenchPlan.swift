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
        return ToolchainBenchPlan(
            id: tool.id, isStack: false, platform: platform, installer: describe(tool.installer(for: platform), tool),
            category: tool.category, requires: tool.requires.map(\.toolID), selection: selection,
            verify: tool.verify,
            workload: ToolchainWorkloads.workload(for: tool.id) ?? .skip(reason: "no workload defined"))
    }

    static func plan(for stack: ToolchainStack, platform: ToolchainPlatform) -> ToolchainBenchPlan {
        let selection = ToolchainCatalog.selection(from: .init(stacks: [stack.id]), platform: platform)
        let verify =
            platform == .linux && !stack.linuxSteps.isEmpty ? (stack.linuxVerify ?? stack.verify) : stack.verify
        return ToolchainBenchPlan(
            id: stack.id, isStack: true, platform: platform, installer: describe(stack, selection),
            category: category(of: stack), requires: stack.requires.map(\.toolID), selection: selection,
            verify: verify, workload: ToolchainWorkloads.workload(for: stack.id) ?? .skip(reason: "no workload defined")
        )
    }

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
