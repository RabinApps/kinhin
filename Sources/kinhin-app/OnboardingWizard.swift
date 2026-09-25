import AppKit
import KinhinKit

/// The first-run wizard: three short steps that reuse the same forms as the
/// Setup tab, so nothing is entered in two different places.
////// 1. **Connect** — paste a GitHub token, pick the repo or org to serve
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
class OnboardingWizardViewController: NSViewController {
    /// Fired when the user presses Start fleet.
    var onFinished: (() -> Void)?
    /// Fired when the user leaves setup unfinished ("Finish later").
    var onFinishLater: (() -> Void)?
    /// Persists a token and live-swaps it into a running engine (injected by
    /// the app; defaults to a Keychain save).
    var saveToken: ((ForgeID, String) async throws -> Void)? {
        didSet { if let saveToken { connectForm.saveToken = saveToken } }
    }

    // MARK: Step model

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
                    "kinhin runs your CI jobs on this Mac. Connect GitHub, a self-hosted Gitea, or both: paste a token, then choose the repository (or organization) to serve."
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

    private(set) var step: Step = .connect
    private let header = NSTextField(labelWithString: "")
    private let subheader = NSTextField(wrappingLabelWithString: "")
    private let content = NSView()
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let nextButton = NSButton(title: "Continue", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip for now", target: nil, action: nil)
    private var headerStack: NSStackView?
    private var headerHeight: NSLayoutConstraint?

    private let connectForm = ConnectFormViewController()
    private let macForm = MacToolsFormViewController()
    private let toolchainsForm = ToolchainsViewController(seed: .allOff)
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("OnboardingWizardViewController is created in code") }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        header.font = .systemFont(ofSize: 22, weight: .bold)
        subheader.font = .systemFont(ofSize: 12)
        subheader.textColor = .secondaryLabelColor
        subheader.maximumNumberOfLines = 3

        let headerStack = NSStackView(views: [header, subheader])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        self.headerStack = headerStack

        content.translatesAutoresizingMaskIntoConstraints = false

        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(backClicked)
        nextButton.bezelStyle = .rounded
        nextButton.keyEquivalent = "\r"
        nextButton.target = self
        nextButton.action = #selector(nextClicked)
        skipButton.bezelStyle = .rounded
        skipButton.controlSize = .small
        skipButton.target = self
        skipButton.action = #selector(skipClicked)

        let footer = NSStackView(views: [skipButton, NSView(), backButton, nextButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: 13)
        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.preferredMaxLayoutWidth = FormKit.formWidth

        container.addSubview(headerStack)
        container.addSubview(content)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            headerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            headerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),

            content.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            content.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])

        macForm.autoEnableLinuxRuntime = true
        macForm.onReadinessChanged = { [weak self] in self?.refreshButtons() }
        connectForm.onChanged = { [weak self] in self?.refreshButtons() }
        toolchainsForm.onEdited = { [weak self] in self?.refreshButtons() }
        // Point the form at a writable config (the real one in production),
        // so its Apply writes back into config.yaml like the other forms.
        toolchainsForm.configURL = Paths.config

        view = container
        show(.connect)
    }

    // MARK: Step switching

    private func show(_ newStep: Step) {
        step = newStep
        header.stringValue = "Step \(newStep.rawValue + 1) of \(Step.allCases.count) — \(newStep.title)"
        subheader.stringValue = newStep.subtitle
        content.subviews.forEach { $0.removeFromSuperview() }
        removeChildForms()

        let child: NSView
        switch newStep {
        case .connect:
            addChild(connectForm)
            connectForm.reload()
            child = connectForm.view
        case .mac:
            addChild(macForm)
            macForm.reload()
            child = macForm.view
        case .toolchains:
            // No reload here: the form seeds itself when its view loads, and
            // reloading on every visit would discard selections made before
            // stepping back and forth.
            if !children.contains(toolchainsForm) { addChild(toolchainsForm) }
            child = toolchainsForm.view
        case .start:
            updateSummary()
            child = summaryLabel
        }
        child.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(child)
        // Top-aligned: slack collects below the form, never between the
        // subtitle and the controls.
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: content.topAnchor),
            child.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            child.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
        ])
        if newStep == .toolchains {
            // The toolchains page is a scroll view plus a pinned footer with no
            // intrinsic height of its own; without a bottom edge it collapses
            // to just the footer and the grid disappears.
            child.bottomAnchor.constraint(equalTo: content.bottomAnchor).isActive = true
        }
        refreshButtons()

        // NSStackView has no intrinsic height, so pin the header to its
        // fitting size (subtitles differ in line count).
        headerHeight?.isActive = false
        view.layoutSubtreeIfNeeded()
        if let headerStack {
            let constraint = headerStack.heightAnchor.constraint(
                equalToConstant: max(26, headerStack.fittingSize.height))
            constraint.isActive = true
            headerHeight = constraint
        }
    }

    private func removeChildForms() {
        for child in [connectForm, macForm] where children.contains(child) {
            child.removeFromParent()
        }
    }

    private func refreshButtons() {
        backButton.isEnabled = step != .connect
        skipButton.title = step == .start ? "Finish later" : "Skip for now"
        switch step {
        case .connect:
            nextButton.title = "Continue"
        case .mac:
            nextButton.title = "Continue"
        case .toolchains:
            nextButton.title = "Continue"
        case .start:
            nextButton.title = "Start fleet"
            nextButton.isEnabled = missingItems.isEmpty
            updateSummary()
        }
        if step != .start { nextButton.isEnabled = true }
    }

    /// What still blocks starting (empty → ready).
    private var missingItems: [String] {
        var missing: [String] = []
        if !connectForm.isConnected {
            missing.append("Connect GitHub or Gitea and choose a repository or org (step 1).")
        }
        if !macForm.isReady {
            missing.append(
                "Set up something to run jobs on (step 2): a Linux runtime (Docker or Apple container), or tart for macOS jobs."
            )
        }
        if toolchainsForm.hasPendingChanges {
            missing.append("Apply your toolchain selection in step 3 before starting the fleet.")
        }
        return missing
    }

    private func updateSummary() {
        let snap = ConfigStore.snapshotOrLog()
        let repo = (snap?.repo == ConfigLoader.templateRepo ? "" : snap?.repo) ?? ""
        var lines = [
            "Serving:  \(repo.isEmpty ? (snap?.gitea == nil ? "— not chosen yet" : "Gitea only") : repo)",
            "Gitea:  \(snap?.gitea.map { "\($0.scope) @ \($0.instance)" } ?? "not used")",
            "Runs on:  \(macForm.runsOnDescription)",
        ]
        // Summarize the step-3 toolchain selection on the final "Ready to
        // go" step, so the user sees exactly what will be preinstalled.
        let selectedTools = toolchainsForm.working.tools.compactMap { key, _ in key }.sorted()
        let selectedStacks = toolchainsForm.working.stacks.compactMap { key, _ in key }.sorted()
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
        summaryLabel.stringValue = lines.joined(separator: "\n")
    }

    // MARK: Navigation

    /// Test hooks: the @objc actions are private.
    func nextClickedForTesting() { nextClicked() }
    func skipClickedForTesting() { skipClicked() }
    func backClickedForTesting() { backClicked() }
    var connectFormForTesting: ConnectFormViewController { connectForm }
    var macFormForTesting: MacToolsFormViewController { macForm }

    @objc private func backClicked() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        show(previous)
    }

    @objc private func nextClicked() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            if missingItems.isEmpty { onFinished?() }
            return
        }
        show(next)
    }

    @objc private func skipClicked() {
        if step == .start { onFinishLater?() } else { nextClicked() }
    }
}
