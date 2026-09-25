import AppKit
import KinhinKit

// Rebuilding runtime images with the saved toolchain selection.
@MainActor
extension ToolchainsViewController {
    // MARK: Rebuild

    @objc func rebuildClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("rebuild:"),
            let runtime = RuntimeID(rawValue: String(raw.dropFirst("rebuild:".count)))
        else { return }
        startRebuild(runtime)
    }

    @discardableResult
    func startRebuild(_ runtime: RuntimeID) -> Task<Void, Never>? {
        guard !hasPendingChanges else { return nil }
        let platform: ToolchainPlatform = runtime == .tart ? .macOS : .linux
        guard confirmRebuild(runtime, ToolchainsConfigEditor.plan(baseline, for: platform)) else { return nil }
        let cfg: KinhinConfig
        do {
            cfg = try ConfigLoader.load(from: configURL)
        } catch {
            statusLabel.stringValue = "Not started — \(error.localizedDescription)"
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
                self?.reload()
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
    static func rebuildImage(runtime: RuntimeID, config cfg: KinhinConfig) async throws {
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
            let base = LinuxImageOptions.baseImage(
                configured: image, localImages: await AppleContainerRuntime().localImageNames())
            var options = ContainerImagePreparer.Options(image: base, target: image)
            options.toolchains = cfg.toolchains
            try await ContainerImagePreparer(shell: Shell()).prepare(options)
        case .docker:
            guard let image = cfg.docker?.image else { throw ToolchainRebuildError.notConfigured("docker") }
            let base = LinuxImageOptions.baseImage(
                configured: image, localImages: await DockerRuntime(image: image).localImageNames())
            var options = DockerImagePreparer.Options(image: base, target: image)
            options.toolchains = cfg.toolchains
            try await DockerImagePreparer(shell: Shell()).prepare(options)
        case .host:
            break
        }
    }
}

enum ToolchainRebuildError: LocalizedError {
    case notConfigured(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured(let name): return "\(name) isn't set up in config.yaml."
        }
    }
}
