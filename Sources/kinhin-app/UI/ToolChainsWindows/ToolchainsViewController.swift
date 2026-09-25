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
    /// How the grid is seeded when the view loads.
    enum Seed {
        /// From the saved config (every catalog entry ON when it has no
        /// `toolchains:` section) — the Advanced → Toolchains page.
        case fromConfig
        /// Every tool and stack OFF, nothing read from disk — the setup
        /// wizard's step, where the user explicitly picks what to preinstall.
        case allOff
    }

    let seed: Seed
    var configURL: URL = Paths.config
    var onEdited: (() -> Void)?

    /// Confirms a rebuild. Injectable so tests never open a modal.
    var confirmRebuild: (_ runtime: RuntimeID, _ plan: ToolchainsConfigEditor.Plan) -> Bool = { runtime, plan in
        var text =
            "This replaces the current image with a fresh one that includes your saved tools. It can take 10–30 minutes and downloads a lot."
        text +=
            plan.installing.isEmpty
            ? "\n\nNo tools are selected: the image will have only the runner agents."
            : "\n\nInstalling: \(plan.installing.joined(separator: ", "))."
        if !plan.skipped.isEmpty {
            text += "\n\nSkipped (not available for this runtime): \(plan.skipped.joined(separator: ", "))."
        }
        return AlertKit.confirm(
            title: "Rebuild the \(ToolchainsViewController.runtimeTitle(runtime)) image?", message: text,
            confirmTitle: "Rebuild Image", style: .informational)
    }
    /// Runs the actual image build for a runtime (real implementation below).
    var rebuild: (_ runtime: RuntimeID, _ config: KinhinConfig) async throws -> Void = { runtime, cfg in
        try await ToolchainsViewController.rebuildImage(runtime: runtime, config: cfg)
    }

    var baseline = ToolchainsSelection()
    internal var working = ToolchainsSelection()

    let stack = NSStackView()
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    let progress = NSProgressIndicator()
    var toolChecks: [String: NSButton] = [:]

    var toolVersions: [String: NSTextField] = [:]
    var stackChecks: [String: NSButton] = [:]
    var stackVersions: [String: NSTextField] = [:]
    var brewField: NSTextField?
    var specsField: NSTextField?
    var rebuildButtons: [RuntimeID: NSButton] = [:]
    var busy = false

    init(seed: Seed = .fromConfig) {
        self.seed = seed
        super.init(nibName: nil, bundle: nil)
    }
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
        switch seed {
        case .fromConfig:
            reload()
        case .allOff:
            working = ToolchainsSelection()
            refreshState()
        }
        render()
    }

    // MARK: Loading

    /// Says why the config could not be loaded, instead of a blank grid.
    func showLoadError(_ error: Error) {
        statusLabel.stringValue =
            "config.yaml has a problem — \(error.localizedDescription). Use Advanced → App → Open config file."
        statusLabel.textColor = .systemRed
    }

    func reload() {
        let loaded: ToolchainsSelection
        do {
            loaded = try ToolchainsConfigEditor.selection(from: ConfigStore.text(at: configURL))
        } catch {
            showLoadError(error)
            return
        }
        baseline = loaded
        // Seed the grid: every catalog tool/stack ON by default when the
        // config has no toolchains: section, so the page is never blank.
        working = loaded.isEmpty ? catalogSelection() : loaded
        refreshState()
    }

    /// A "everything on by default" selection mirroring the catalog, used to
    /// keep the grid populated before the user has written any config.
    func catalogSelection() -> ToolchainsSelection {
        var out = ToolchainsSelection()
        for entry in ToolchainCatalog.tools {
            out.tools[entry.id] = ""
        }
        for stack in ToolchainCatalog.stacks {
            out.stacks[stack.id] = ""
        }
        return out
    }

    /// Same as `reload()`, but seeds the grid with every catalog tool/stack
    /// OFF by default. Used by the setup wizard where there is no saved config
    /// and the user has to pick each toolchain explicitly.
    internal func reload(allOff: Bool = false) {
        let loaded: ToolchainsSelection
        do {
            loaded = try ToolchainsConfigEditor.selection(from: ConfigStore.text(at: configURL))
        } catch {
            showLoadError(error)
            return
        }
        baseline = loaded
        if allOff {
            // Seed all OFF: the user must explicitly enable each toolchain.
            working = ToolchainsSelection()
        } else {
            working = loaded.isEmpty ? catalogSelection() : loaded
        }
        refreshState()
    }

    // MARK: Editing (working copy only; Apply writes)

    @objc internal func entryToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let isStack = id.hasPrefix("stack:")
        let key = isStack ? String(id.dropFirst("stack:".count)) : String(id.dropFirst("tool:".count))
        if isStack {
            working.stacks[key] =
                sender.state == .on ? (stackVersions[key]?.stringValue.trimmingCharacters(in: .whitespaces) ?? "") : nil
            stackVersions[key]?.isEnabled = stackVersions[key] != nil && sender.state == .on
        } else {
            working.tools[key] =
                sender.state == .on ? (toolVersions[key]?.stringValue.trimmingCharacters(in: .whitespaces) ?? "") : nil
            toolVersions[key]?.isEnabled = toolVersions[key] != nil && sender.state == .on
        }
        refreshState()
    }

    @objc func shareToggled(_ sender: NSButton) {
        working.shareCache = sender.state == .on
        refreshState()
    }

    func controlTextDidChange(_ notification: Notification) { commitField(notification.object as? NSTextField) }
    func controlTextDidEndEditing(_ notification: Notification) { commitField(notification.object as? NSTextField) }

    func commitField(_ field: NSTextField?) {
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

    internal func refreshState() {
        let pending = hasPendingChanges
        let problems = ToolchainsConfigEditor.requirementProblems(working)
        applyButton.isEnabled = pending && problems.isEmpty && !busy
        revertButton.isEnabled = pending && !busy
        for button in rebuildButtons.values { button.isEnabled = !pending && !busy }

        // Restore checkbox states from working after a reload.
        for entry in ToolchainCatalog.tools {
            toolChecks[entry.id]?.state = working.tools[entry.id] != nil ? .on : .off
        }
        for stack in ToolchainCatalog.stacks {
            stackChecks[stack.id]?.state = working.stacks[stack.id] != nil ? .on : .off
        }

        if !problems.isEmpty {
            statusLabel.stringValue = problems.joined(separator: " ")
            statusLabel.textColor = .systemOrange
        } else if pending {
            statusLabel.stringValue = "Unapplied changes. Apply, then rebuild an image."
            statusLabel.textColor = .systemOrange
        } else if !busy, !statusLabel.stringValue.hasPrefix("Applied"), !statusLabel.stringValue.hasPrefix("Rebuilt"),
            !statusLabel.stringValue.hasPrefix("Not")
        {
            statusLabel.stringValue = ""
        }
    }

    @objc internal func revertClicked() {
        statusLabel.stringValue = ""
        reload()
    }

    @objc internal func applyClicked() { apply() }

    func apply() {
        do {
            try ToolchainsConfigEditor.apply(working, to: configURL)
            baseline = working
            statusLabel.stringValue = "Applied ✓ — rebuild an image below to use it."
            statusLabel.textColor = .systemGreen
            refreshState()
            onEdited?()
        } catch {
            statusLabel.stringValue = "Not applied — \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
        }
    }
}
