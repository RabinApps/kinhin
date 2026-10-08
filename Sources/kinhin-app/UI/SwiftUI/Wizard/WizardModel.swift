import Foundation
import KinhinKit
import Observation

/// State behind the first-run wizard: the step, and the forms it
/// reuses from the Setup tab so nothing is entered in two different places.
///
/// 1. **Connect** — paste a token for each forge to serve and pick the repo,
///    project or group.
/// 2. **This Mac** — install tart and prepare the runner image; optionally
///    enable Linux runtimes. The disk and time cost of the image is shown here.
/// 3. **Review & Start** — a plain-language summary and "Start fleet". A
///    "Tune it" disclosure holds the optional Capacity split and the
///    Toolchains note; the defaults are fine.
///
/// Every choice is written as soon as it is made, so leaving the wizard at
/// any point keeps the progress. "Continue" and "Start fleet" are disabled
/// while something blocks them, and the view says what, beside the button.
/// An image still being prepared does not block Start: the preparation
/// continues in the background and macOS jobs begin when it finishes.
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
        case review = 2

        var title: String {
            switch self {
            case .connect: return "Connect your code"
            case .mac: return "Get this Mac ready"
            case .review: return "Review & Start"
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
            case .review:
                return "Everything you chose is saved. You can change any of it later in the Setup tab."
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
    /// The "Tune it" disclosure on the review step (Capacity and Toolchains).
    var tuneItExpanded = false
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
    var canSkip: Bool { step != .review }
    /// The Setup wizard shows an Open config.yaml button on every step.
    var showsOpenConfigButton: Bool { true }
    var skipTitle: String { "Skip for now" }
    var nextTitle: String { step == .review ? "Start fleet" : "Continue" }
    var canGoBack: Bool { step != .connect }
    /// Continue / Start fleet is enabled only when nothing blocks the current step.
    var canContinue: Bool { blockers(for: step).isEmpty }

    /// What blocks the current step, in plain language (empty → can continue).
    /// The view shows these beside the disabled button.
    var currentBlockers: [String] { blockers(for: step) }

    /// What still blocks starting (empty → ready).
    var missingItems: [String] { connectBlockers + macBlockers }

    func blockers(for step: Step) -> [String] {
        switch step {
        case .connect: return connectBlockers
        case .mac: return macBlockers
        case .review: return missingItems
        }
    }

    private var connectBlockers: [String] {
        connect.isConnected
            ? [] : ["Connect \(Self.forgeNames) and choose a repository, project or group (step 1)."]
    }

    /// An image that is being prepared counts: Start does not wait for it.
    private var macBlockers: [String] {
        mac.isReady || mac.isPreparingImage
            ? []
            : [
                "Set up something to run jobs on (step 2): a Linux runtime (Docker or Apple container), or tart for macOS jobs."
            ]
    }

    // MARK: - Navigation

    func show(_ newStep: Step) {
        step = newStep
        switch newStep {
        case .connect:
            connect.reload()
        case .mac:
            mac.reload()
        case .review:
            runtimes.reload()
            refreshSummary()
        }
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        show(previous)
    }

    /// Continue / Start fleet. Does nothing while `canContinue` is false (the
    /// view disables the button and shows `currentBlockers` beside it); on
    /// the last step it saves the auto-start choice and finishes.
    func next() {
        guard canContinue else { return }
        advance()
    }

    /// Skip for now: moves on without the step's blockers being cleared. The
    /// last step cannot be skipped, so setup can't be left half-done.
    func skip() {
        if canSkip { advance() }
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            AppPreferences.setAutoStartFleet(autoStartFleet, in: defaults)
            onFinished?()
            return
        }
        show(next)
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
        if mac.isPreparingImage {
            lines.append(
                "Image:  still being prepared (about \(ImagePrepCost.macOSDiskGB) GB). It keeps going in the background; macOS jobs start once it finishes."
            )
        }
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
