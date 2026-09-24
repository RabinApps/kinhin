import AppKit
import KinhinKit

/// Advanced → Toolchains: choose what gets preinstalled into your runner
/// images, and rebuild the images with it.
///
/// - Tools and stacks come from kinhin's catalog; each row says whether it
///   applies to macOS (tart), Linux (Docker / Apple container), or both.
/// - Nothing is written until **Apply**; a tool that needs Node (pnpm,
///   Playwright…) can't be applied without Node also selected, same as the
///   engine's own rule.
/// - Changes only reach an image when it is rebuilt, so each runtime has a
///   **Rebuild image…** button with a confirmation dialog.
@MainActor
final class ToolchainsViewController: NSViewController, NSTextFieldDelegate {
    var configURL: URL = Paths.config
    var onEdited: (() -> Void)?

    /// Confirms a rebuild. Injectable so tests never open a modal.
    var confirmRebuild: (_ runtime: RuntimeID, _ plan: ToolchainsConfigEditor.Plan) -> Bool = { runtime, plan in
        let alert = NSAlert()
        alert.messageText = "Rebuild the \(ToolchainsViewController.runtimeTitle(runtime)) image?"
        var text = "This replaces the current image with a fresh one that includes your saved tools. It can take 10–30 minutes and downloads a lot."
        text += plan.installing.isEmpty ? "\n\nNo tools are selected: the image will have only the runner agents." : "\n\nInstalling: \(plan.installing.joined(separator: ", "))."
        if !plan.skipped.isEmpty { text += "\n\nSkipped (not available for this runtime): \(plan.skipped.joined(separator: ", "))." }
        alert.informativeText = text
        alert.addButton(withTitle: "Rebuild Image")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// Runs the actual image build for a runtime (real implementation below).
    var rebuild: (_ runtime: RuntimeID, _ config: kinhinConfig) async throws -> Void = { runtime, cfg in
        try await ToolchainsViewController.rebuildImage(runtime: runtime, config: cfg)
    }

    private var baseline = ToolchainsSelection()
    private var working = ToolchainsSelection()

    private let stack = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private var toolChecks: [String: NSButton] = [:]
    private var toolVersions: [String: NSTextField] = [:]
    private var stackChecks: [String: NSButton] = [:]
    private var stackVersions: [String: NSTextField] = [:]
    private var brewField: NSTextField?
    private var specsField: NSTextField?
    private var rebuildButtons: [RuntimeID: NSButton] = [:]
    private var busy = false

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("created in code") }

    override func loadView() {
        let (scroll, column) = FormKit.scrollingColumn()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(stack)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = 300
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applyClicked)
        applyButton.identifier = NSUserInterfaceItemIdentifier("toolchains-apply")
        revertButton.bezelStyle = .rounded
        revertButton.target = self
        revertButton.action = #selector(revertClicked)
        let footer = FormKit.row([progress, statusLabel, FormKit.spacer(), revertButton, applyButton])
        footer.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scroll)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            footer.widthAnchor.constraint(equalToConstant: FormKit.formWidth),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        reload()
    }

    // MARK: Loading

    func reload() {
        let yaml = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard let loaded = try? ToolchainsConfigEditor.selection(from: yaml) else {
            statusLabel.stringValue = "config.yaml doesn't parse — use Advanced → App → Open config file."
            statusLabel.textColor = .systemRed
            return
        }
        baseline = loaded
        working = loaded
        render()
        refreshState()
    }

    // MARK: Rendering

    private func render() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        toolChecks.removeAll(); toolVersions.removeAll(); stackChecks.removeAll(); stackVersions.removeAll()
        rebuildButtons.removeAll()

        let intro = FormKit.hint("Pick what your jobs need preinstalled. Changes take effect when you rebuild an image below. Tools marked “macOS only” are skipped for Linux images.")
        stack.addArrangedSubview(intro)

        let mise = ToolchainCatalog.tools.filter { if case .mise = $0.installer { return true } else { return false } }
        let npm = ToolchainCatalog.tools.filter { if case .npm = $0.installer { return true } else { return false } }
        let other = ToolchainCatalog.tools.filter { entry in !mise.contains(entry) && !npm.contains(entry) }
        stack.addArrangedSubview(toolsCard("Languages & runtimes", mise))
        stack.addArrangedSubview(toolsCard("JavaScript tools (need Node)", npm))
        stack.addArrangedSubview(toolsCard("CLIs & other", other))
        stack.addArrangedSubview(stacksCard())
        stack.addArrangedSubview(extrasCard())
        stack.addArrangedSubview(imagesCard())
    }

    private func platformLabel(_ platforms: [ToolchainPlatform], hasLinuxInstaller: Bool = false) -> String {
        let set = Set(platforms)
        return set.contains(.macOS) && set.contains(.linux) ? "macOS · Linux" : (set.contains(.macOS) ? "macOS only" : "Linux only")
    }

    private func toolsCard(_ title: String, _ entries: [ToolchainEntry]) -> NSView {
        let card = FormKit.card(title: title)
        for entry in entries {
            let check = NSButton(checkboxWithTitle: entry.id, target: self, action: #selector(toolToggled(_:)))
            check.state = working.tools[entry.id] != nil ? .on : .off
            check.identifier = NSUserInterfaceItemIdentifier("tool:\(entry.id)")
            toolChecks[entry.id] = check

            let versionable: Bool
            switch entry.installer {
            case .mise, .npm: versionable = true
            default: versionable = false
            }
            let field = NSTextField(string: working.tools[entry.id] ?? "")
            field.placeholderString = versionable ? (entry.defaultSpec.split(separator: "@").dropFirst().first.map(String.init) ?? "latest") : "—"
            field.isEnabled = versionable && working.tools[entry.id] != nil
            field.identifier = NSUserInterfaceItemIdentifier("toolver:\(entry.id)")
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 96).isActive = true
            field.setAccessibilityLabel("\(entry.id) version")
            toolVersions[entry.id] = field

            let tag = NSTextField(labelWithString: platformLabel(entry.platforms, hasLinuxInstaller: entry.linuxInstaller != nil))
            tag.font = .systemFont(ofSize: 10)
            tag.textColor = .secondaryLabelColor
            let row = FormKit.row([check, FormKit.spacer(), tag, field])
            row.widthAnchor.constraint(equalToConstant: FormKit.formWidth - 28).isActive = true
            card.column.addArrangedSubview(row)
            card.column.addArrangedSubview(FormKit.hint(entry.summary))
        }
        return card.card
    }

    private func stacksCard() -> NSView {
        let card = FormKit.card(title: "Stacks", subtitle: "Bundled recipes: several tools installed together.")
        for stack in ToolchainCatalog.stacks {
            let check = NSButton(checkboxWithTitle: stack.id, target: self, action: #selector(stackToggled(_:)))
            check.state = working.stacks[stack.id] != nil ? .on : .off
            check.identifier = NSUserInterfaceItemIdentifier("stack:\(stack.id)")
            stackChecks[stack.id] = check
            let field = NSTextField(string: working.stacks[stack.id] ?? "")
            field.placeholderString = stack.versionKind == nil ? "—" : (stack.defaultVersion.isEmpty ? "latest" : stack.defaultVersion)
            field.isEnabled = stack.versionKind != nil && working.stacks[stack.id] != nil
            field.identifier = NSUserInterfaceItemIdentifier("stackver:\(stack.id)")
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 96).isActive = true
            stackVersions[stack.id] = field
            let tag = NSTextField(labelWithString: platformLabel(stack.platforms))
            tag.font = .systemFont(ofSize: 10)
            tag.textColor = .secondaryLabelColor
            let row = FormKit.row([check, FormKit.spacer(), tag, field])
            row.widthAnchor.constraint(equalToConstant: FormKit.formWidth - 28).isActive = true
            card.column.addArrangedSubview(row)
            card.column.addArrangedSubview(FormKit.hint(stack.summary))
        }
        return card.card
    }

    private func extrasCard() -> NSView {
        let card = FormKit.card(title: "Other", subtitle: "Anything not in the lists above. Comma-separated.")
        let brew = NSTextField(string: working.extraBrew.joined(separator: ", "))
        brew.placeholderString = "wget, cmake"
        brew.identifier = NSUserInterfaceItemIdentifier("extra-brew")
        brew.delegate = self
        brew.widthAnchor.constraint(equalToConstant: 260).isActive = true
        brewField = brew
        let specs = NSTextField(string: working.extraSpecs.joined(separator: ", "))
        specs.placeholderString = "zig@0.13"
        specs.identifier = NSUserInterfaceItemIdentifier("extra-specs")
        specs.delegate = self
        specs.widthAnchor.constraint(equalToConstant: 260).isActive = true
        specsField = specs
        card.column.addArrangedSubview(FormKit.row([FormKit.label("Homebrew"), brew]))
        card.column.addArrangedSubview(FormKit.hint("Homebrew packages: macOS images only."))
        card.column.addArrangedSubview(FormKit.row([FormKit.label("Other tools"), specs]))
        card.column.addArrangedSubview(FormKit.hint("Any tool mise can install, as name@version."))

        let share = NSButton(checkboxWithTitle: "Share the download cache with runners", target: self, action: #selector(shareToggled(_:)))
        share.state = working.shareCache ? .on : .off
        share.identifier = NSUserInterfaceItemIdentifier("share-cache")
        card.column.addArrangedSubview(share)
        card.column.addArrangedSubview(FormKit.hint("Per-job installs (npm ci, mise install…) reuse downloads instead of fetching them again."))
        return card.card
    }

    /// One row per runtime that is actually set up, saying what its image will
    /// contain and offering a rebuild.
    private func imagesCard() -> NSView {
        let card = FormKit.card(title: "Rebuild images", subtitle: "Your saved tools are baked in when an image is rebuilt.")
        let snapshot = (try? String(contentsOf: configURL, encoding: .utf8)).flatMap { try? GeneralConfigEditor.snapshot(from: $0) }
        var runtimes: [(RuntimeID, ToolchainPlatform)] = []
        if TartController.isInstalled() { runtimes.append((.tart, .macOS)) }
        if snapshot?.container != nil { runtimes.append((.appleContainer, .linux)) }
        if snapshot?.docker != nil { runtimes.append((.docker, .linux)) }
        if runtimes.isEmpty {
            card.column.addArrangedSubview(FormKit.hint("No runtime is set up yet. Set one up in Advanced → Accounts."))
        }
        for (runtime, platform) in runtimes {
            let plan = ToolchainsConfigEditor.plan(baseline, for: platform)
            let title = NSTextField(labelWithString: Self.runtimeTitle(runtime))
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            var detailText = plan.installing.isEmpty ? "No tools selected." : "Installs \(plan.installing.count): \(plan.installing.joined(separator: ", "))"
            if !plan.skipped.isEmpty { detailText += " · skips \(plan.skipped.joined(separator: ", "))" }
            let detail = FormKit.hint(detailText)
            detail.preferredMaxLayoutWidth = 300
            let text = NSStackView(views: [title, detail])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 1
            let button = NSButton(title: "Rebuild Image…", target: self, action: #selector(rebuildClicked(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.identifier = NSUserInterfaceItemIdentifier("rebuild:\(runtime.rawValue)")
            rebuildButtons[runtime] = button
            let row = FormKit.row([text, FormKit.spacer(), button])
            row.widthAnchor.constraint(equalToConstant: FormKit.formWidth - 28).isActive = true
            card.column.addArrangedSubview(row)
        }
        return card.card
    }

    static func runtimeTitle(_ runtime: RuntimeID) -> String {
        switch runtime {
        case .tart: return "macOS image (tart)"
        case .appleContainer: return "Linux image (Apple container)"
        case .docker: return "Linux image (Docker)"
        case .host: return "host"
        }
    }

    // MARK: Editing (working copy only; Apply writes)

    @objc private func toolToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue.dropFirst("tool:".count).description else { return }
        if sender.state == .on {
            working.tools[id] = toolVersions[id]?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        } else {
            working.tools[id] = nil
        }
        syncVersionEnabled()
        refreshState()
    }

    @objc private func stackToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue.dropFirst("stack:".count).description else { return }
        working.stacks[id] = sender.state == .on ? (stackVersions[id]?.stringValue.trimmingCharacters(in: .whitespaces) ?? "") : nil
        syncVersionEnabled()
        refreshState()
    }

    @objc private func shareToggled(_ sender: NSButton) {
        working.shareCache = sender.state == .on
        refreshState()
    }

    private func syncVersionEnabled() {
        for entry in ToolchainCatalog.tools {
            var versionable = false
            switch entry.installer { case .mise, .npm: versionable = true; default: break }
            toolVersions[entry.id]?.isEnabled = versionable && working.tools[entry.id] != nil
        }
        for stack in ToolchainCatalog.stacks {
            stackVersions[stack.id]?.isEnabled = stack.versionKind != nil && working.stacks[stack.id] != nil
        }
    }

    func controlTextDidChange(_ notification: Notification) { commitField(notification.object as? NSTextField) }
    func controlTextDidEndEditing(_ notification: Notification) { commitField(notification.object as? NSTextField) }

    private func commitField(_ field: NSTextField?) {
        guard let field, let id = field.identifier?.rawValue else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        if id.hasPrefix("toolver:") {
            let tool = String(id.dropFirst("toolver:".count))
            if working.tools[tool] != nil { working.tools[tool] = value }
        } else if id.hasPrefix("stackver:") {
            let stackID = String(id.dropFirst("stackver:".count))
            if working.stacks[stackID] != nil { working.stacks[stackID] = value }
        } else if id == "extra-brew" {
            working.extraBrew = Self.splitList(value)
        } else if id == "extra-specs" {
            working.extraSpecs = Self.splitList(value)
        }
        refreshState()
    }

    static func splitList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: State

    var hasPendingChanges: Bool { working != baseline }

    private func refreshState() {
        let pending = hasPendingChanges
        let problems = ToolchainsConfigEditor.requirementProblems(working)
        applyButton.isEnabled = pending && problems.isEmpty && !busy
        revertButton.isEnabled = pending && !busy
        for button in rebuildButtons.values { button.isEnabled = !pending && !busy }
        if !problems.isEmpty {
            statusLabel.stringValue = problems.joined(separator: " ")
            statusLabel.textColor = .systemOrange
        } else if pending {
            statusLabel.stringValue = "Unapplied changes. Apply, then rebuild an image."
            statusLabel.textColor = .systemOrange
        } else if !busy, !statusLabel.stringValue.hasPrefix("Applied"), !statusLabel.stringValue.hasPrefix("Rebuilt"), !statusLabel.stringValue.hasPrefix("Not") {
            statusLabel.stringValue = ""
        }
    }

    @objc private func revertClicked() {
        statusLabel.stringValue = ""
        reload()
    }

    @objc private func applyClicked() { apply() }

    func apply() {
        do {
            try ToolchainsConfigEditor.apply(working, to: configURL)
            baseline = working
            statusLabel.stringValue = "Applied ✓ — rebuild an image below to use it."
            statusLabel.textColor = .systemGreen
            render()
            refreshState()
            onEdited?()
        } catch {
            statusLabel.stringValue = "Not applied — \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
        }
    }

    // MARK: Rebuild

    @objc private func rebuildClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("rebuild:"),
              let runtime = RuntimeID(rawValue: String(raw.dropFirst("rebuild:".count))) else { return }
        startRebuild(runtime)
    }

    @discardableResult
    func startRebuild(_ runtime: RuntimeID) -> Task<Void, Never>? {
        guard !hasPendingChanges else { return nil }
        let platform: ToolchainPlatform = runtime == .tart ? .macOS : .linux
        guard confirmRebuild(runtime, ToolchainsConfigEditor.plan(baseline, for: platform)) else { return nil }
        guard let cfg = try? ConfigLoader.load(from: configURL) else {
            statusLabel.stringValue = "Not started — config.yaml is missing or invalid."
            statusLabel.textColor = .systemRed
            return nil
        }
        busy = true
        progress.startAnimation(nil)
        statusLabel.stringValue = "Rebuilding the \(Self.runtimeTitle(runtime))… this can take a while."
        statusLabel.textColor = .secondaryLabelColor
        refreshState()
        let rebuild = self.rebuild
        return Task { [weak self] in
            do {
                try await rebuild(runtime, cfg)
                self?.statusLabel.stringValue = "Rebuilt the \(Self.runtimeTitle(runtime)) ✓"
                self?.statusLabel.textColor = .systemGreen
            } catch {
                self?.statusLabel.stringValue = "Not rebuilt — \(error.localizedDescription)"
                self?.statusLabel.textColor = .systemRed
            }
            self?.busy = false
            self?.progress.stopAnimation(nil)
            self?.refreshState()
        }
    }

    /// The real image builds (same calls the setup checklist and CLI make).
    static func rebuildImage(runtime: RuntimeID, config cfg: kinhinConfig) async throws {
        switch runtime {
        case .tart:
            let tart = try TartController(configuredPath: cfg.tartPath)
            var options = ImagePreparer.Options()
            options.provisionScriptPath = cfg.provisionScript
            options.toolchains = cfg.toolchains
            try await ImagePreparer(tart: tart, ssh: SSHExecutor()).run(options)
        case .appleContainer:
            guard let image = cfg.container?.image else { throw ToolchainRebuildError.notConfigured("container") }
            try await SetupWindowController.startContainerSystem(shell: Shell())
            var options = ContainerImagePreparer.Options(image: image, target: image)
            options.toolchains = cfg.toolchains
            try await ContainerImagePreparer(shell: Shell()).prepare(options)
        case .docker:
            guard let image = cfg.docker?.image else { throw ToolchainRebuildError.notConfigured("docker") }
            var options = DockerImagePreparer.Options(image: image, target: image)
            options.toolchains = cfg.toolchains
            try await DockerImagePreparer(shell: Shell()).prepare(options)
        case .host:
            break
        }
    }

    // MARK: Test hooks

    func toggleToolForTesting(_ id: String, version: String = "", on: Bool = true) {
        working.tools[id] = on ? version : nil
        refreshState()
    }
    func toggleStackForTesting(_ id: String, on: Bool = true) {
        working.stacks[id] = on ? "" : nil
        refreshState()
    }
    func setShareCacheForTesting(_ on: Bool) { working.shareCache = on; refreshState() }
    var statusTextForTesting: String { statusLabel.stringValue }
    var applyEnabledForTesting: Bool { applyButton.isEnabled }
    var rebuildEnabledForTesting: [RuntimeID: Bool] { rebuildButtons.mapValues(\.isEnabled) }
    var workingForTesting: ToolchainsSelection { working }
}

enum ToolchainRebuildError: LocalizedError {
    case notConfigured(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured(let name): return "\(name) isn't set up in config.yaml."
        }
    }
}
