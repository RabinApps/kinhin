import Foundation
import KinhinKit
import Observation

/// State behind the first-run wizard: the step, and the forms it
/// reuses from the Setup tab so nothing is entered in two different places.
///
/// 1. **Connect** — paste a GitHub token, pick the repo or org to serve
///    (optionally add a self-hosted Gitea).
/// 2. **This Mac** — install tart and prepare the runner image; optionally
///    enable Linux runtimes.
/// 3. **Capacity** — split the Mac's capacity between the enabled runtimes
///    (the Runtimes pane's Budget card). With one runtime enabled it says
///    there is nothing to split; Skip passes it.
/// 4. **Toolchains** — an informational page: toolchains are declared per
///    repo (`.kinhin.yml`, `projects:`), so there is nothing to choose or save.
/// 5. **Start** — a plain-language summary and "Start fleet".
///
/// Every choice is written as soon as it is made, so leaving the wizard at
/// any point keeps the progress. "Start fleet" is only enabled once the fleet
/// can actually start, so the app never loops back into setup.
@MainActor
@Observable
final class WizardModel {
    /// Every forge by name for prose: "GitHub, GitLab, Gitea or Forgejo".
    nonisolated static var forgeNames: String {
        let names = ForgeID.allCases.map(\.displayName)
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " or " + last
    }

    enum Step: Int, CaseIterable {
        case connect = 0
        case mac = 1
        case capacity = 2
        case toolchains = 3
        case start = 4

        var title: String {
            switch self {
            case .connect: return "Connect your code"
            case .mac: return "Get this Mac ready"
            case .capacity: return "Split your capacity"
            case .toolchains: return "Toolchains"
            case .start: return "Ready to go"
            }
        }

        var subtitle: String {
            switch self {
            case .connect:
                return
                    "kinhin runs your CI jobs on this Mac. Select the forges to serve — \(WizardModel.forgeNames) — then paste a token and choose the repository, project or group to serve for each."
            case .mac:
                return
                    "Choose what runs your jobs: Linux (Docker, Apple container, or a full Linux VM), macOS virtual machines (tart), or both. You only need one — the button below walks the comparison."
            case .capacity:
                return
                    "Decide how much of this Mac each runtime gets. Drag a slider or type a percent; lock a pool to keep its share fixed while the others rebalance. The default split is fine if you're unsure."
            case .toolchains:
                return
                    "Nothing to choose here: every repo declares its own toolchains, and nothing is installed until a job needs it."
            case .start: return "Everything you chose is saved. You can change any of it later in the Setup tab."
            }
        }
    }

    /// Fired when the user presses Start fleet.
    @ObservationIgnored var onFinished: (() -> Void)?
    /// Open config.yaml from the Setup wizard's button row.
    @ObservationIgnored var openConfig: (() -> Void)?

    let connect = ConnectModel()
    let mac = MacToolsModel()
    /// The Budget card's model, shared with the Runtimes pane's editing code.
    let runtimes = RuntimesModel()

    private(set) var step: Step = .connect
    /// The "Ready to go" summary, refreshed each time that step is shown.
    private(set) var summaryText = ""
    /// "Start the fleet whenever kinhin opens": defaults on here (a CI
    /// runner is usually wanted running); saved when the user starts the fleet.
    var autoStartFleet = true
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Setup with nothing to run jobs on switches on an installed Linux
        // runtime so the wizard can finish.
        mac.autoEnableLinuxRuntime = true
    }

    // MARK: - Derived

    var header: String { "Step \(step.rawValue + 1) of \(Step.allCases.count) — \(step.title)" }
    /// Steps before the last can be skipped; setup itself cannot be left early.
    var canSkip: Bool { step != .start }
    /// The Setup wizard shows an Open config.yaml button on every step that has
    /// the standard Skip / Back / Continue row.
    var showsOpenConfigButton: Bool { canSkip || step == .start }
    var skipTitle: String { "Skip for now" }
    var nextTitle: String { step == .start ? "Start fleet" : "Continue" }
    var canGoBack: Bool { step != .connect }
    var canContinue: Bool { step != .start || missingItems.isEmpty }

    /// What still blocks starting (empty → ready).
    var missingItems: [String] {
        var missing: [String] = []
        if !connect.isConnected {
            missing.append(
                "Connect \(Self.forgeNames) and choose a repository, project or group (step 1).")
        }
        if !mac.isReady {
            missing.append(
                "Set up something to run jobs on (step 2): a Linux runtime (Docker or Apple container), or tart for macOS jobs."
            )
        }
        return missing
    }

    // MARK: - Navigation

    func show(_ newStep: Step) {
        step = newStep
        switch newStep {
        case .connect:
            connect.reload()
        case .mac:
            mac.reload()
        case .capacity:
            runtimes.reload()
        case .toolchains:
            break  // informational: no state to load or validate
        case .start:
            refreshSummary()
        }
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        show(previous)
    }

    func next() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            if missingItems.isEmpty {
                AppPreferences.setAutoStartFleet(autoStartFleet, in: defaults)
                onFinished?()
            }
            return
        }
        show(next)
    }

    func skip() {
        if canSkip { next() }
    }

    // MARK: - Summary

    /// "tart 50% · docker 30% · appleContainer 20%" once a split is chosen.
    private var capacitySummary: String? {
        guard runtimes.showsBudget, !(runtimes.currentRuntimeConfig?.budget.isEmpty ?? true) else { return nil }
        let parts = runtimes.budgetRows.filter { $0.share > 0 }.map {
            "\($0.id.rawValue) \(Int(($0.share * 100).rounded()))%"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func refreshSummary() {
        var accounts: [AccountConfig]
        do {
            accounts = try AccountsConfigEditor.accounts()
        } catch {
            // No file yet or unreadable config: the summary shows "not chosen
            // yet"; the real error surfaces when the config is saved.
            Log.warn("config", "could not read accounts for the summary: \(error.localizedDescription)")
            accounts = []
        }
        var lines: [String] = []
        if accounts.isEmpty {
            lines.append("Serving:  — not chosen yet")
        } else {
            lines.append("Serving:")
            for account in accounts {
                var line = "•  \(account.scope)"
                if let instance = account.instance, !instance.isEmpty {
                    line += " @ \(instance)"
                }
                line += " — \(account.forge.displayName), account \(account.name)"
                lines.append(line)
            }
        }
        lines.append("Runs on:  \(mac.runsOnDescription)")
        if let capacity = capacitySummary { lines.append("Capacity:  \(capacity)") }
        let missing = missingItems
        if !missing.isEmpty {
            lines.append("")
            lines.append("Still needed:")
            lines.append(contentsOf: missing.map { "•  \($0)" })
        }
        summaryText = lines.joined(separator: "\n")
    }

}
