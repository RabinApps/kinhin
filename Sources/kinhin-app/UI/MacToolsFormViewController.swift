import AppKit
import KinhinKit

/// "This Mac": what kinhin runs jobs on, with real actions instead of
/// instructions. macOS jobs need tart and a prepared base image (both can be
/// fixed here); Linux jobs can optionally use Apple container or Docker
/// (toggling writes the config section with sensible defaults).
///
/// Shared by the onboarding wizard and the Setup tab.
@MainActor
final class MacToolsFormViewController: NSViewController {
    /// The config file this form edits (tests point it at a scratch file).
    var configURL: URL = Paths.config
    var onChanged: (() -> Void)?

    /// True when tart is installed and the configured base image exists.
    private(set) var isReady = false
    var onReadinessChanged: (() -> Void)?

    private let tartStatus = NSTextField(labelWithString: "Checking…")
    private let tartButton = NSButton(title: "Install", target: nil, action: nil)
    private let imageStatus = NSTextField(labelWithString: "")
    private let imageButton = NSButton(title: "Prepare image", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let busyLabel = NSTextField(labelWithString: "")

    private let containerToggle = NSButton(checkboxWithTitle: "Apple container — Linux jobs", target: nil, action: nil)
    private let containerStatus = NSTextField(labelWithString: "")
    private let dockerToggle = NSButton(checkboxWithTitle: "Docker — Linux jobs", target: nil, action: nil)
    private let dockerStatus = NSTextField(labelWithString: "")

    private let stack = NSStackView()

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("created in code") }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(buildMacCard())
        stack.addArrangedSubview(buildLinuxCard())

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        view = container
        reload()
    }

    // MARK: Construction

    private func buildMacCard() -> NSView {
        let (card, column) = FormKit.card(
            title: "macOS jobs",
            subtitle: "Jobs run in disposable macOS virtual machines powered by tart."
        )
        for status in [tartStatus, imageStatus, busyLabel] {
            status.font = .systemFont(ofSize: 11)
            status.textColor = .secondaryLabelColor
        }
        tartButton.bezelStyle = .rounded
        tartButton.controlSize = .small
        tartButton.target = self
        tartButton.action = #selector(installTart)
        tartButton.identifier = NSUserInterfaceItemIdentifier("mac-install-tart")
        imageButton.bezelStyle = .rounded
        imageButton.controlSize = .small
        imageButton.target = self
        imageButton.action = #selector(prepareImage)
        imageButton.identifier = NSUserInterfaceItemIdentifier("mac-prepare-image")
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        column.addArrangedSubview(FormKit.row([FormKit.label("tart", weight: .semibold), tartStatus, FormKit.spacer(), tartButton]))
        column.addArrangedSubview(FormKit.row([FormKit.label("Base image", weight: .semibold), imageStatus, FormKit.spacer(), imageButton]))
        column.addArrangedSubview(FormKit.row([progress, busyLabel]))
        return card
    }

    private func buildLinuxCard() -> NSView {
        let (card, column) = FormKit.card(
            title: "Linux jobs (optional)",
            subtitle: "Turn these on to also run Linux workflows. You can leave both off."
        )
        containerToggle.target = self
        containerToggle.action = #selector(containerToggled)
        containerToggle.identifier = NSUserInterfaceItemIdentifier("mac-container-toggle")
        dockerToggle.target = self
        dockerToggle.action = #selector(dockerToggled)
        dockerToggle.identifier = NSUserInterfaceItemIdentifier("mac-docker-toggle")
        for status in [containerStatus, dockerStatus] {
            status.font = .systemFont(ofSize: 11)
            status.textColor = .secondaryLabelColor
        }
        column.addArrangedSubview(FormKit.row([containerToggle, containerStatus]))
        column.addArrangedSubview(FormKit.row([dockerToggle, dockerStatus]))
        return card
    }

    // MARK: State

    func reload() {
        let yaml = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let snapshot = try? GeneralConfigEditor.snapshot(from: yaml)
        containerToggle.state = snapshot?.container != nil ? .on : .off
        dockerToggle.state = snapshot?.docker != nil ? .on : .off
        let containerInstalled = Paths.findExecutable(named: "container") != nil
        let dockerInstalled = Paths.findExecutable(named: "docker") != nil
        containerStatus.stringValue = containerInstalled ? "installed ✓" : "not installed (github.com/apple/container)"
        dockerStatus.stringValue = dockerInstalled ? "installed ✓" : "not installed (Docker Desktop, OrbStack or colima)"

        let image = snapshot?.image ?? "tahoe-base"
        let tartInstalled = TartController.isInstalled()
        tartStatus.stringValue = tartInstalled ? "installed ✓" : "not installed"
        tartStatus.textColor = tartInstalled ? .secondaryLabelColor : .systemOrange
        tartButton.isHidden = tartInstalled
        guard tartInstalled else {
            imageStatus.stringValue = "needs tart first"
            imageButton.isHidden = true
            setReady(false)
            return
        }
        imageStatus.stringValue = "checking \(image)…"
        imageButton.isHidden = true
        Task { [weak self] in
            let present = await Task.detached { () -> Bool in
                guard let tart = try? TartController() else { return false }
                return ((try? await tart.list()) ?? []).contains { $0.name == image }
            }.value
            guard let self else { return }
            self.imageStatus.stringValue = present ? "\(image) ready ✓" : "\(image) not prepared yet — takes a while, once"
            self.imageStatus.textColor = present ? .secondaryLabelColor : .systemOrange
            self.imageButton.isHidden = present
            self.setReady(present)
        }
    }

    private func setReady(_ ready: Bool) {
        guard ready != isReady else { return }
        isReady = ready
        onReadinessChanged?()
    }

    // MARK: Actions

    private func run(_ title: String, _ body: @escaping @Sendable () async throws -> Void) {
        tartButton.isEnabled = false
        imageButton.isEnabled = false
        busyLabel.stringValue = title
        busyLabel.textColor = .secondaryLabelColor
        progress.startAnimation(nil)
        Task { [weak self] in
            do {
                try await body()
                self?.busyLabel.stringValue = ""
            } catch {
                self?.busyLabel.stringValue = "Failed — \(error.localizedDescription)"
                self?.busyLabel.textColor = .systemRed
            }
            self?.progress.stopAnimation(nil)
            self?.tartButton.isEnabled = true
            self?.imageButton.isEnabled = true
            self?.reload()
        }
    }

    @objc private func installTart() {
        run("Installing tart with Homebrew…") {
            let shell = Shell()
            let repair = TartHealthProbe.repairs(for: .missing)[0]
            try await SetupWindowController.run(repair, shell: shell)
            let health = await TartHealthProbe(shell: shell).check()
            if health != .healthy {
                throw NSError(domain: "kinhin", code: 1, userInfo: [NSLocalizedDescriptionKey: "tart didn't launch after installing."])
            }
        }
    }

    @objc private func prepareImage() {
        run("Preparing the runner image — this takes a while, but only once…") {
            let cfg = try ConfigLoader.load()
            let tart = try TartController(configuredPath: cfg.tartPath)
            var options = ImagePreparer.Options()
            options.provisionScriptPath = cfg.provisionScript
            options.toolchains = cfg.toolchains
            try await ImagePreparer(tart: tart, ssh: SSHExecutor()).run(options)
        }
    }

    @objc private func containerToggled() {
        let snap = (try? String(contentsOf: configURL, encoding: .utf8)).flatMap { try? GeneralConfigEditor.snapshot(from: $0) }
        write(.container(containerToggle.state == .on ? (snap?.container ?? .init(image: "kinhin-ci-linux", cpus: 4, memoryGB: 8)) : nil), revert: containerToggle)
    }

    @objc private func dockerToggled() {
        let snap = (try? String(contentsOf: configURL, encoding: .utf8)).flatMap { try? GeneralConfigEditor.snapshot(from: $0) }
        write(.docker(dockerToggle.state == .on ? (snap?.docker ?? .init(image: "kinhin-ci-linux", cpus: 2, memoryGB: 4, maxSlots: 8)) : nil), revert: dockerToggle)
    }

    private func write(_ field: GeneralConfigEditor.Field, revert toggle: NSButton) {
        do {
            try GeneralConfigEditor.apply(field, to: configURL)
            onChanged?()
        } catch {
            toggle.state = toggle.state == .on ? .off : .on
            busyLabel.stringValue = "Not saved — \(error.localizedDescription)"
            busyLabel.textColor = .systemRed
        }
    }

    // MARK: Test hooks

    func setContainerForTesting(_ on: Bool) { containerToggle.state = on ? .on : .off; containerToggled() }
    func setDockerForTesting(_ on: Bool) { dockerToggle.state = on ? .on : .off; dockerToggled() }
}
