import Foundation
import KinhinKit
import Observation

/// State behind the first-run wizard: the step, and the three forms it
/// reuses from the Setup tab so nothing is entered in two different places.
///
/// 1. **Connect** — paste a GitHub token, pick the repo or org to serve
///    (optionally add a self-hosted Gitea).
/// 2. **This Mac** — install tart and prepare the runner image; optionally
///    enable Linux runtimes.
/// 3. **Select toolchains** — pick what runtimes/tools to preinstall into
///    your runner images. Everything starts OFF so the user chooses.
/// 4. **Start** — a plain-language summary and "Start fleet".
///
/// Every choice is written as soon as it is made, so leaving the wizard at
/// any point keeps the progress. "Start fleet" is only enabled once the fleet
/// can actually start, so the app never loops back into setup.
@MainActor
@Observable
final class WizardModel {
    enum Step: Int, CaseIterable {
        case connect = 0
        case mac = 1
        case toolchains = 2
        case start = 3

        var title: String {
            switch self {
            case .connect: return "Connect your code"
            case .mac: return "Get this Mac ready"
            case .toolchains: return "Select your toolchains"
            case .start: return "Ready to go"
            }
        }

        var subtitle: String {
            switch self {
            case .connect:
                return
                    "kinhin runs your CI jobs on this Mac. Select the forges to serve — GitHub, GitLab, Gitea or Forgejo — then paste a token and choose the repository, project or group to serve for each."
            case .mac:
                return
                    "Choose what runs your jobs: Linux (Docker or Apple container), macOS virtual machines (tart), or both. You only need one."
            case .toolchains:
                return
                    "Pick every tool and stack that should be preinstalled in each runner image. Nothing is installed until you apply."
            case .start: return "Everything you chose is saved. You can change any of it later in the Setup tab."
            }
        }
    }

    /// Fired when the user presses Start fleet.
    @ObservationIgnored var onFinished: (() -> Void)?
    /// Fired when the user leaves setup unfinished ("Finish later").
    @ObservationIgnored var onFinishLater: (() -> Void)?

    let connect = ConnectModel()
    let mac = MacToolsModel()
    let toolchains = ToolchainsModel(seed: .allOff)

    private(set) var step: Step = .connect
    /// The "Ready to go" summary, refreshed each time that step is shown.
    private(set) var summaryText = ""
    private var toolchainsLoaded = false
    /// "Start the fleet whenever kinhin opens": defaults on here (a CI
    /// runner is usually wanted running); saved when the user starts the fleet.
    var autoStartFleet = true
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Setup with nothing to run jobs on switches on an installed Linux
        // runtime so the wizard can finish.
        mac.autoEnableLinuxRuntime = true
        // The wizard's Apply writes back into the real config.yaml, like
        // the other forms.
        toolchains.configURL = Paths.config
    }

    // MARK: - Derived

    var header: String { "Step \(step.rawValue + 1) of \(Step.allCases.count) — \(step.title)" }
    var skipTitle: String { step == .start ? "Finish later" : "Skip for now" }
    var nextTitle: String { step == .start ? "Start fleet" : "Continue" }
    var canGoBack: Bool { step != .connect }
    var canContinue: Bool { step != .start || missingItems.isEmpty }

    /// What still blocks starting (empty → ready).
    var missingItems: [String] {
        var missing: [String] = []
        if !connect.isConnected {
            missing.append(
                "Connect GitHub, GitLab, Gitea or Forgejo and choose a repository, project or group (step 1).")
        }
        if !mac.isReady {
            missing.append(
                "Set up something to run jobs on (step 2): a Linux runtime (Docker or Apple container), or tart for macOS jobs."
            )
        }
        if toolchains.hasPendingChanges {
            missing.append("Apply your toolchain selection in step 3 before starting the fleet.")
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
        case .toolchains:
            // Load once: reloading on every visit would discard selections
            // made before stepping back and forth.
            if !toolchainsLoaded {
                toolchainsLoaded = true
                toolchains.reload()
            }
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
        if step == .start { onFinishLater?() } else { next() }
    }

    // MARK: - Summary

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
        // Summarize the step-3 toolchain selection on the final "Ready to
        // go" step, so the user sees exactly what will be preinstalled.
        let selectedTools = toolchains.working.tools.keys.sorted()
        let selectedStacks = toolchains.working.stacks.keys.sorted()
        if !selectedTools.isEmpty {
            lines.append("Toolchains:  \(selectedTools.joined(separator: ", "))")
        }
        if !selectedStacks.isEmpty {
            lines.append("Stacks:  \(selectedStacks.joined(separator: ", "))")
        }
        let missing = missingItems
        if !missing.isEmpty {
            lines.append("")
            lines.append("Still needed:")
            lines.append(contentsOf: missing.map { "•  \($0)" })
        }
        summaryText = lines.joined(separator: "\n")
    }
}
