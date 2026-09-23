import AppKit
import OrchardKit

@MainActor
extension SetupWindowController {
    // MARK: Actions

    @objc func runAction(_ sender: NSButton) {
        let action = sender.identifier?.rawValue ?? ""
        Log.info("setup", "action dispatched: \(action)")
        switch action {
        case "fix_clt":
            fixCLT()
        case "install_tart", "reinstall_tart":
            installTart()
        case "rollback_tart":
            rollbackTart()
        case "create_config":
            createConfig()
        case "edit_config":
            editConfig()
        case "repair_provision_script":
            repairProvisionScript()
        case "enter_token":
            openTokenSettings(.github)
        case "replace_token":
            openTokenSettings(.github)
        case "enter_gitea_token":
            openTokenSettings(.gitea)
        case "replace_gitea_token":
            openTokenSettings(.gitea)
        case "prepare_image":
            prepareImage()
        case "install_container_cli":
            installContainerCLI()
        case "start_container_system":
            startContainerSystem()
        case "prepare_container_image":
            prepareContainerImage()
        default:
            Log.error("setup", "no handler for action '\(action)'")
        }
    }

    /// Installs Apple's `container` CLI via Homebrew, then starts its
    /// system service. Skips the install when the CLI is already healthy.
    private func installContainerCLI() {
        runLongTask(title: "Installing Apple container via Homebrew…") {
            let shell = Shell()
            if !(await AppleContainerRuntime(shell: shell).health()).isReady {
                let brew = Paths.findExecutable(named: "brew") ?? "/opt/homebrew/bin/brew"
                let result = try await shell.run([brew, "install", "--cask", "container"], cwd: nil, timeout: 900)
                guard result.succeeded else {
                    throw NSError(domain: "orchard", code: 1, userInfo: [NSLocalizedDescriptionKey: result.stderr.isEmpty ? "brew install --cask container failed" : result.stderr])
                }
            }
            try await Self.startContainerSystem(shell: shell)
        }
    }

    /// Starts the container system service if it isn't running.
    private func startContainerSystem() {
        runLongTask(title: "Starting the container system…") {
            let shell = Shell()
            try await Self.startContainerSystem(shell: shell)
        }
    }

    static func startContainerSystem(shell: ShellRunning) async throws {
        guard !(await AppleContainerRuntime(shell: shell).health()).isReady else { return }
        let result = try await shell.run(
            [AppleContainerRuntime.resolvedBinaryPath, "system", "start"],
            cwd: nil, timeout: 120
        )
        guard result.succeeded else {
            throw NSError(domain: "orchard", code: 1, userInfo: [NSLocalizedDescriptionKey: result.stderr.isEmpty ? "container system start failed" : result.stderr])
        }
    }

    /// Bakes the runner agents into the configured Linux container image.
    private func prepareContainerImage() {
        runLongTask(title: "Preparing container image (this takes a while)…") {
            guard let cfg = try? ConfigLoader.load(), let image = cfg.container?.image else {
                throw NSError(domain: "orchard", code: 2, userInfo: [NSLocalizedDescriptionKey: "config missing, invalid, or no container.image set"])
            }
            try await Self.startContainerSystem(shell: Shell())
            let preparer = ContainerImagePreparer(shell: Shell())
            try await preparer.prepare(image: image, target: image)
        }
    }

    private func installTart() {
        runRepair(TartHealthProbe.repairs(for: .missing)[0], progressTitle: "Installing tart via Homebrew…")
    }

    private func rollbackTart() {
        runRepair(TartHealthProbe.repairs(for: .killedOnLaunch)[0], progressTitle: "Rolling back to the notarized Cirrus Labs tart…")
    }

    /// Runs a repair plan's commands, then verifies tart actually launches.
    func runRepair(_ repair: TartRepair, progressTitle: String) {
        runLongTask(title: progressTitle) {
            let shell = Shell()
            // Check-then-repair: skip Homebrew entirely when tart already launches.
            guard await TartHealthProbe(shell: shell).check() != .healthy else { return }
            try await Self.run(repair, shell: shell)
            // A "successful" install can still be a Gatekeeper kill — verify.
            let health = await TartHealthProbe(shell: shell).check()
            if health != .healthy {
                let plan = TartHealthProbe.repairs(for: health).first
                let hint = plan.map { " Follow up with: \($0.commandLine)" } ?? ""
                throw NSError(domain: "orchard", code: 1, userInfo: [NSLocalizedDescriptionKey: "tart did not launch after the operation.\(hint)"])
            }
        }
    }

    static func run(_ repair: TartRepair, shell: ShellRunning) async throws {
        for command in repair.commands {
            let result = try await shell.run(command, cwd: nil, timeout: 900)
            guard result.succeeded else {
                let what = command.joined(separator: " ")
                throw NSError(domain: "orchard", code: 1, userInfo: [NSLocalizedDescriptionKey: result.stderr.isEmpty ? "brew failed: \(what)" : result.stderr])
            }
        }
    }

    private func createConfig() {
        Paths.ensureSupportDirectories()
        if !FileManager.default.fileExists(atPath: Paths.config.path) {
            try? ConfigLoader.template().write(toFile: Paths.config.path, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(Paths.config.deletingLastPathComponent())
        Task { await refreshChecks() }
    }

    /// Template exists but still carries the placeholder repo — open the file
    /// itself for editing (falls back to revealing its folder when no default
    /// YAML editor is set), then re-check.
    private func editConfig() {
        Paths.ensureSupportDirectories()
        NSWorkspace.shared.open(Paths.config)
        Task { await refreshChecks() }
    }

    /// The provision-script row's fix: the broken path lives in config.yaml
    /// (the row's detail names it), so open the file for editing and re-check.
    private func repairProvisionScript() {
        Paths.ensureSupportDirectories()
        NSWorkspace.shared.open(Paths.config)
        Task { await refreshChecks() }
    }

    /// Command Line Tools are missing/outdated. Reinstalling needs sudo, so
    /// copy the exact command and hand the user a Terminal to run and approve
    /// it in — then re-check.
    private func fixCLT() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(CLTRepair.commandLine, forType: .string)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Reinstall Command Line Tools"
        alert.informativeText = "The reinstall command was copied to your clipboard and Terminal is opening. Paste (⌘V), press Return, and approve the administrator prompt.\n\n\(CLTRepair.commandLine)\n\n\(CLTRepair.fallbackHint)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        Task { await refreshChecks() }
    }

    /// Token rows open the shared token settings form (same surface as the
    /// status-bar menu); the checklist refreshes after each save.
    private func openTokenSettings(_ forge: ForgeID) {
        onOpenTokenSettings?(forge)
        Task { await refreshChecks() }
    }

    private func prepareImage() {
        runLongTask(title: "Preparing runner image (this takes a while)…") {
            guard let cfg = try? ConfigLoader.load() else {
                throw NSError(domain: "orchard", code: 2, userInfo: [NSLocalizedDescriptionKey: "config missing or invalid"])
            }
            let tart = try TartController(configuredPath: cfg.tartPath)
            let preparer = ImagePreparer(tart: tart, ssh: SSHExecutor())
            var options = ImagePreparer.Options()
            // The app's one-click prepare bakes the config's provision
            // script too (same rule as the CLI's `image prepare`).
            options.provisionScriptPath = cfg.provisionScript
            try await preparer.run(options)
        }
    }

    @objc func openTerminal() {
        // The CLI walks the same checklist (`orchard setup-status`); hand the
        // user a terminal so both paths feel first-class.
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    @objc func startFleet() {
        guard canStart else { return }
        onFinished?()
        close()
    }

    private func runLongTask(title: String, _ body: @escaping () async throws -> Void) {
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 0, height: 16))
        progress.isIndeterminate = true
        progress.startAnimation(nil)

        // Explicit container + constraints (never a bare stack as contentView —
        // same fragility that blanked the setup window).
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 90))
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(NSTextField(labelWithString: title))
        stack.addArrangedSubview(progress)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
        ])
        window.contentView = container
        window.center()
        window.makeKeyAndOrderFront(nil)

        Task {
            do {
                try await body()
                window.close()
                await refreshChecks()
            } catch {
                window.close()
                let alert = NSAlert(error: error)
                alert.runModal()
                await refreshChecks()
            }
        }
    }
}
