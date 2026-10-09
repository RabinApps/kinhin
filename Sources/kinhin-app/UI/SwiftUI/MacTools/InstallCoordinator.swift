import AppKit
import Foundation
import KinhinKit
import Observation

/// The open install-confirmation sheet's inputs: what will run and the
/// methods to choose from (the list is the host's supported options).
struct InstallOffer: Identifiable {
    let tool: InstallableTool
    let options: [InstallOption]
    var id: String { tool.rawValue }
}

/// The open missing-Homebrew sheet's inputs. The manual download is
/// offered only when the tool has a direct download URL.
struct MissingBrewOffer: Identifiable {
    let tool: InstallableTool
    let options: [InstallOption]
    var id: String { tool.rawValue }
    var manualURL: URL? { options.first?.manualURL }
}

/// The shell, host probe and confirmation seams the "This Mac" form and its
/// collaborators share. Production defaults hit the real Mac; tests replace
/// the fields they care about.
@MainActor
final class MacToolsSeams {
    var installShell: ShellRunning = Shell()
    /// Whether a tool is installed afterwards (real PATH lookup by default).
    var installedCheck: @Sendable (InstallableTool) -> Bool = { $0.isInstalled }
    var brewPath: () -> String? = { RuntimeInstaller.brewPath }
    /// The Mac install options are judged against (real probe by default).
    var hostFacts: () -> HostFacts = { .current() }
    /// Confirms replacing an existing image (real alert by default; tests inject a closure).
    var confirmRebuild: (_ title: String, _ message: String) -> Bool = { title, message in
        AlertKit.confirm(
            title: title, message: message,
            confirmTitle: String(
                localized: "Rebuild", bundle: .l10n, comment: "Confirm button of the rebuild-image alert"),
            destructive: true)
    }
    /// Shown instead of the confirmation when no option can run on this Mac.
    var explainUnsupported: (InstallableTool, Error) -> Void = { tool, error in
        AlertKit.present(
            error: error,
            title: String(
                localized: "\(tool.title) can't run on this Mac", bundle: .l10n,
                comment: "Alert title; %@ is a tool name such as Docker"))
    }
}

/// Everything that installs a tool or runs a long action on the "This Mac"
/// form: the confirmation / missing-Homebrew / Linux-runtime sheets, the
/// install itself, and the busy line and Cancel button shared by every long
/// action (installs and image builds). `reload` runs when an action ends.
@MainActor
@Observable
final class InstallCoordinator {
    typealias Line = StatusLine

    /// A long-running action (install, prepare image) is in flight.
    private(set) var busy = false
    var busyLine = Line(text: "")
    /// The task behind the current `busy` action, so the Cancel button can
    /// stop it (an image build then unwinds through its scratch-VM cleanup
    /// and keeps the previous image).
    @ObservationIgnored private(set) var runningTask: Task<Void, Never>?

    /// The open install-confirmation sheet's inputs, or nil.
    var installOffer: InstallOffer?
    /// The open missing-Homebrew sheet's inputs, or nil.
    var missingBrewOffer: MissingBrewOffer?
    /// The open Linux-runtime choice sheet's inputs, or nil.
    var linuxSetupOffer: LinuxRuntimeSetup.Offer?

    @ObservationIgnored private let seams: MacToolsSeams
    @ObservationIgnored private let reload: () -> Void

    init(seams: MacToolsSeams, reload: @escaping () -> Void) {
        self.seams = seams
        self.reload = reload
    }

    // MARK: - Long actions

    /// Runs a long action with the busy spinner/line managed around it.
    /// `cancelledLine` is shown when the action is cancelled (default fits
    /// installs; image builds pass their own reassurance). The task is kept
    /// in `runningTask` so `cancelRunning()` can stop it.
    @discardableResult
    func run(
        _ title: String,
        cancelledLine: String = String(
            localized: "Cancelled", bundle: .l10n, comment: "This Mac form: shown after cancelling an action"),
        _ body: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, Never> {
        busy = true
        busyLine = Line(text: title)
        let task = Task { [weak self] in
            do {
                try await body()
                self?.busyLine = Line(text: "")
            } catch is CancellationError {
                self?.busyLine = Line(text: cancelledLine, style: .warn)
            } catch {
                self?.busyLine = Line(
                    text: String(
                        localized: "Failed — \(error.localizedDescription)", bundle: .l10n,
                        comment: "This Mac form: failure line; %@ is the reason"), style: .error)
            }
            self?.busy = false
            self?.runningTask = nil
            self?.reload()
        }
        runningTask = task
        return task
    }

    /// The Cancel button's action: cancels the in-flight action. Cancellation
    /// is cooperative — image builds remove their scratch VM and keep the
    /// previous image; child processes are killed by `Shell`.
    func cancelRunning() {
        runningTask?.cancel()
    }

    @discardableResult
    func startContainerService() -> Task<Void, Never> {
        let shell = seams.installShell
        return run(
            String(
                localized: "Starting the Apple container service…", bundle: .l10n,
                comment: "This Mac form: progress line")
        ) {
            try await AppleContainerRuntime.startSystem(shell: shell)
        }
    }

    /// Appends the by-hand command to a failed install's busy line.
    func noteManualCommandFallback(_ command: String) {
        guard busyLine.style == .error else { return }
        busyLine.text += String(
            localized: "\nYou can also run this in Terminal: \(command)", bundle: .l10n,
            comment: "This Mac form: hint appended to a failed install; %@ is a shell command")
    }

    // MARK: - Starting an install

    /// Install… pressed: confirm in a sheet before anything runs — or, when
    /// no option can run (no Homebrew), explain in a sheet instead.
    func install(_ tool: InstallableTool) {
        let host = seams.hostFacts()
        do {
            try HostRequirements.ensureSupported(tool, on: host)
        } catch {
            seams.explainUnsupported(tool, error)
            return
        }
        let options = HostRequirements.offeredOptions(for: tool, on: host)
        guard seams.brewPath() != nil || options.contains(where: { !$0.needsBrew }) else {
            missingBrewOffer = MissingBrewOffer(tool: tool, options: options)
            return
        }
        installOffer = InstallOffer(tool: tool, options: options)
    }

    /// Presents the Linux-runtime choice sheet from the form's "Set up Linux jobs…" button.
    func chooseLinuxRuntime() {
        linuxSetupOffer = LinuxRuntimeChooser.offer(on: seams.hostFacts()) { [weak self] offer in
            if let offer { self?.applyLinuxRuntime(offer) }
        }
    }

    /// The user confirmed a Linux runtime in the sheet: install it.
    private func applyLinuxRuntime(_ offer: LinuxRuntimeSetup.Offer) {
        guard let tool = offer.tool else { return }
        linuxSetupOffer = nil
        install(tool)
    }

    // MARK: - Confirmation actions

    /// Install pressed in the sheet: close it, then run the chosen option.
    func confirmInstall(_ option: InstallOption) {
        guard let offer = installOffer else { return }
        installOffer = nil
        startInstall(option, tool: offer.tool)
    }

    /// Copy Command pressed in the sheet: the chosen option's command goes to
    /// the clipboard and nothing runs. The sheet closes (matching the alert
    /// it replaces); the copied command is the takeaway.
    func copyInstallCommand(_ option: InstallOption) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(option.commandLine, forType: .string)
        installOffer = nil
    }

    /// Cancel pressed (or the sheet was dismissed): nothing runs.
    func cancelInstall() {
        installOffer = nil
    }

    // MARK: - Missing-Homebrew actions

    /// Get Homebrew pressed: open brew.sh and close the sheet.
    func openBrewSite() {
        if let url = URL(string: "https://brew.sh") {
            NSWorkspace.shared.open(url)
        }
        missingBrewOffer = nil
    }

    /// Download pressed: open the tool's manual URL and close the sheet.
    func downloadManually() {
        if let url = missingBrewOffer?.manualURL {
            NSWorkspace.shared.open(url)
        }
        missingBrewOffer = nil
    }

    /// Cancel pressed (or the sheet was dismissed).
    func cancelMissingBrew() {
        missingBrewOffer = nil
    }

    // MARK: - The install itself

    /// Confirm → install → re-check. On failure, tell the user how to do it
    /// by hand (the busy line carries the exact command).
    private func startInstall(_ choice: InstallOption, tool: InstallableTool) {
        let host = seams.hostFacts()
        let shell = seams.installShell
        let brew = seams.brewPath()
        let installed = seams.installedCheck
        let name = tool.title
        let task = run(
            String(
                localized: "Installing \(name)… this can take several minutes.", bundle: .l10n,
                comment: "This Mac form: progress line; %@ is a tool name")
        ) {
            try await RuntimeInstaller.install(
                choice, tool: tool, shell: shell, brew: brew, host: host, isInstalled: installed)
        }
        Task { [weak self] in
            await task.value
            self?.noteManualCommandFallback(choice.commandLine)
        }
    }
}
