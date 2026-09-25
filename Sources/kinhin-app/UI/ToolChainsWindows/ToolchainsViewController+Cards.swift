import AppKit
import KinhinKit

// Rendering the tool, stack, extras, and image cards.
@MainActor
extension ToolchainsViewController {
    // MARK: Rendering

    internal func render() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        toolChecks.removeAll(); toolVersions.removeAll(); stackChecks.removeAll(); stackVersions.removeAll()
        rebuildButtons.removeAll()
        baseImagePickers.removeAll()

        let intro = FormKit.hint(
            "Pick what your jobs need preinstalled. Changes take effect when you rebuild an image below.")
        stack.addArrangedSubview(intro)
        let note = FormKit.hint(
            "Every row shows its platform note: “macOS · Linux” applies to both, “macOS only” skips on Linux, “Linux only” skips on macOS. Version fields pin a specific version (e.g. node@22)."
        )
        stack.addArrangedSubview(note)

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

    func platformLabel(_ platforms: [ToolchainPlatform], hasLinuxInstaller: Bool = false) -> String {
        let set = Set(platforms)
        return set.contains(.macOS) && set.contains(.linux)
            ? "macOS · Linux" : (set.contains(.macOS) ? "macOS only" : "Linux only")
    }

    func toolsCard(_ title: String, _ entries: [ToolchainEntry]) -> NSView {
        let card = FormKit.card(title: title)
        for entry in entries {
            let check = NSButton(checkboxWithTitle: entry.id, target: self, action: #selector(entryToggled(_:)))
            check.state = working.tools[entry.id] != nil ? .on : .off
            check.identifier = NSUserInterfaceItemIdentifier("tool:\(entry.id)")
            toolChecks[entry.id] = check

            let versionable: Bool
            switch entry.installer {
            case .mise, .npm: versionable = true
            default: versionable = false
            }
            let selected = working.tools[entry.id]
            // The field displays the default spec (or "—") so it is never blank;
            // what it stores goes through `normalizedVersion`, so neither the
            // "node@" prefix nor the dash ever reaches config.yaml.
            let field = NSTextField(
                string: selected.flatMap { !$0.isEmpty ? $0 : nil }
                    ?? (entry.defaultSpec.isEmpty ? "—" : entry.defaultSpec))
            field.placeholderString =
                versionable
                ? (entry.defaultSpec.split(separator: "@").dropFirst().first.map(String.init) ?? "latest") : "—"
            field.isEnabled = versionable && selected != nil
            field.identifier = NSUserInterfaceItemIdentifier("toolver:" + entry.id)
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 96).isActive = true
            field.setAccessibilityLabel("\(entry.id) version")
            toolVersions[entry.id] = field

            let tag = NSTextField(
                labelWithString: platformLabel(entry.platforms, hasLinuxInstaller: entry.linuxInstaller != nil))
            tag.font = .systemFont(ofSize: 10)
            tag.textColor = .secondaryLabelColor
            let row = FormKit.row([check, FormKit.spacer(), tag, field])
            row.widthAnchor.constraint(equalToConstant: FormKit.formWidth - 28).isActive = true
            card.column.addArrangedSubview(row)
            card.column.addArrangedSubview(FormKit.hint(entry.summary))
        }
        return card.card
    }

    func stacksCard() -> NSView {
        let card = FormKit.card(title: "Stacks", subtitle: "Bundled recipes: several tools installed together.")
        for stack in ToolchainCatalog.stacks {
            let check = NSButton(checkboxWithTitle: stack.id, target: self, action: #selector(entryToggled(_:)))
            check.state = working.stacks[stack.id] != nil ? .on : .off
            check.identifier = NSUserInterfaceItemIdentifier("stack:\(stack.id)")
            stackChecks[stack.id] = check
            let selected = working.stacks[stack.id]
            let field = NSTextField(
                string: selected.flatMap { !$0.isEmpty ? $0 : nil }
                    ?? (stack.defaultVersion.isEmpty ? "—" : stack.defaultVersion))
            field.placeholderString =
                stack.versionKind == nil
                ? "—"
                : (selected?.isEmpty ?? true ? (stack.defaultVersion.isEmpty ? "latest" : stack.defaultVersion) : "—")
            field.isEnabled = stack.versionKind != nil && selected != nil
            field.identifier = NSUserInterfaceItemIdentifier("stackver:" + stack.id)
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

    func extrasCard() -> NSView {
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

        let share = NSButton(
            checkboxWithTitle: "Share the download cache with runners", target: self,
            action: #selector(shareToggled(_:)))
        share.state = working.shareCache ? .on : .off
        share.identifier = NSUserInterfaceItemIdentifier("share-cache")
        card.column.addArrangedSubview(share)
        card.column.addArrangedSubview(
            FormKit.hint("Per-job installs (npm ci, mise install…) reuse downloads instead of fetching them again."))
        return card.card
    }

    /// One row per runtime that is actually set up, saying what its image will
    /// contain and offering a rebuild.
    func imagesCard() -> NSView {
        let card = FormKit.card(
            title: "Rebuild images", subtitle: "Your saved tools are baked in when an image is rebuilt.")
        let snapshot = ConfigStore.snapshotOrLog(at: configURL)
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
            var detailText =
                plan.installing.isEmpty
                ? "No tools selected." : "Installs \(plan.installing.count): \(plan.installing.joined(separator: ", "))"
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

            // Linux images are baked on a base image the user can change.
            if runtime != .tart {
                let picker = BaseImagePicker(value: snapshot?.baseImage(for: runtime))
                picker.onChange = { [weak self, weak picker] value in
                    self?.saveBaseImage(value, for: runtime, picker: picker)
                }
                baseImagePickers[runtime] = picker
                card.column.addArrangedSubview(
                    FormKit.row([FormKit.label("Base image", weight: .semibold), FormKit.spacer(), picker]))
            }
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
}

extension ToolchainsViewController {
    /// Writes the chosen base image; on failure says why and shows what is
    /// actually saved.
    func saveBaseImage(_ value: String?, for runtime: RuntimeID, picker: BaseImagePicker?) {
        do {
            try GeneralConfigEditor.setBaseImage(value, for: runtime, at: configURL)
            statusLabel.stringValue = "Base image saved — rebuild the image to use it."
            statusLabel.textColor = .secondaryLabelColor
            onEdited?()
        } catch {
            AlertKit.present(error: error, title: "Couldn't save the base image")
            picker?.setValue(ConfigStore.snapshotOrLog(at: configURL)?.baseImage(for: runtime))
        }
    }
}
