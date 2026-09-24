import AppKit
import KinhinKit

/// The first-run wizard: three short steps that reuse the same forms as the
/// Setup tab, so nothing is entered in two different places.
///
/// 1. **Connect** — paste a GitHub token, pick the repo or org to serve
///    (optionally add a self-hosted Gitea).
/// 2. **This Mac** — install tart and prepare the runner image; optionally
///    enable Linux runtimes.
/// 3. **Start** — a plain-language summary and "Start fleet".
///
/// Every choice is written as soon as it is made, so leaving the wizard at
/// any point keeps the progress. "Start fleet" is only enabled once the fleet
/// can actually start, so the app never loops back into setup.
@MainActor
final class OnboardingWizardViewController: NSViewController {
    /// Fired when the user presses Start fleet.
    var onFinished: (() -> Void)?
    /// Persists a token and live-swaps it into a running engine (injected by
    /// the app; defaults to a Keychain save).
    var saveToken: ((ForgeID, String) async throws -> Void)? {
        didSet { if let saveToken { connectForm.saveToken = saveToken } }
    }

    // MARK: Step model

    enum Step: Int, CaseIterable {
        case connect = 0
        case mac = 1
        case start = 2

        var title: String {
            switch self {
            case .connect: return "Connect your code"
            case .mac: return "Get this Mac ready"
            case .start: return "Ready to go"
            }
        }

        var subtitle: String {
            switch self {
            case .connect: return "kinhin runs your CI jobs on this Mac. Connect GitHub, a self-hosted Gitea, or both: paste a token, then choose the repository (or organization) to serve."
            case .mac: return "macOS jobs run in disposable virtual machines. kinhin can install what's missing."
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

        macForm.onReadinessChanged = { [weak self] in self?.refreshButtons() }
        connectForm.onChanged = { [weak self] in self?.refreshButtons() }

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
        refreshButtons()

        // NSStackView has no intrinsic height, so pin the header to its
        // fitting size (subtitles differ in line count).
        headerHeight?.isActive = false
        view.layoutSubtreeIfNeeded()
        if let headerStack {
            let constraint = headerStack.heightAnchor.constraint(equalToConstant: max(26, headerStack.fittingSize.height))
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
        skipButton.isHidden = step == .start
        switch step {
        case .connect:
            nextButton.title = "Continue"
        case .mac:
            nextButton.title = "Continue"
        case .start:
            nextButton.title = "Start fleet"
            nextButton.isEnabled = missingItems().isEmpty
            updateSummary()
        }
        if step != .start { nextButton.isEnabled = true }
    }

    /// What still blocks starting (empty → ready).
    private func missingItems() -> [String] {
        var missing: [String] = []
        if !connectForm.isConnected { missing.append("Connect GitHub or Gitea and choose a repository or org (step 1).") }
        if !macForm.isReady { missing.append("Install tart and prepare the runner image (step 2).") }
        return missing
    }

    private func updateSummary() {
        let yaml = (try? String(contentsOf: Paths.config, encoding: .utf8)) ?? ""
        let snap = try? GeneralConfigEditor.snapshot(from: yaml)
        let repo = (snap?.repo == ConfigLoader.templateRepo ? "" : snap?.repo) ?? ""
        var lines = [
            "Serving:  \(repo.isEmpty ? (snap?.gitea == nil ? "— not chosen yet" : "Gitea only") : repo)",
            "Gitea:  \(snap?.gitea.map { "\($0.scope) @ \($0.instance)" } ?? "not used")",
            "Runs on:  macOS VMs" + [snap?.container != nil ? "Apple container" : nil, snap?.docker != nil ? "Docker" : nil]
                .compactMap { $0 }.map { " + \($0)" }.joined(),
        ]
        let missing = missingItems()
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
            if missingItems().isEmpty { onFinished?() }
            return
        }
        show(next)
    }

    @objc private func skipClicked() { nextClicked() }
}
