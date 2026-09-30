import AppKit
import Foundation
import KinhinKit

// The install dialogs as SwiftUI sheets (replacing InstallDialogs). The state
// lives on `MacToolsModel`; `MacToolsView` presents `InstallConfirmationSheet`
// / `MissingBrewSheet` while `installOffer` / `missingBrewOffer` are non-nil.

extension MacToolsModel {
    // MARK: - Sheet state

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
        let host = hostFacts()
        let shell = installShell
        let brew = brewPath()
        let installed = installedCheck
        let name = tool.title
        let task = run("Installing \(name)… this can take several minutes.") {
            try await RuntimeInstaller.install(
                choice, tool: tool, shell: shell, brew: brew, host: host, isInstalled: installed)
        }
        // On failure, tell the user how to do it by hand.
        Task { [weak self] in
            await task.value
            self?.noteManualCommandFallback(choice.commandLine)
        }
    }
}
