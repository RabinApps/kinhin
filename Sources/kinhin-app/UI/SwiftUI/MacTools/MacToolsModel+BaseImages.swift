import Foundation
import KinhinKit

// The saved base image per runtime, the Docker platform, and the Linux-on-tart
// toggle: reads from and writes to `config.yaml`.

extension MacToolsModel {
    /// Re-reads the saved base image for each runtime.
    func refreshBaseImages() {
        refreshBaseImages(from: currentSnapshot())
    }

    func refreshBaseImages(from snapshot: GeneralConfigEditor.Snapshot?) {
        tartBaseImage = snapshot?.baseImage(for: .tart)
        fleetLabels = snapshot?.labels ?? []
        containerBaseImage = snapshot?.baseImage(for: .appleContainer)
        dockerBaseImage = snapshot?.baseImage(for: .docker)
        dockerPlatform = snapshot?.dockerPlatform ?? .arm64
    }

    func saveDockerPlatform(_ platform: LinuxPlatform) {
        do {
            try GeneralConfigEditor.setDockerPlatform(platform, at: configURL)
            refreshBaseImages()
            onChanged?()
        } catch {
            installs.busyLine = .notSaved(error)
            refreshBaseImages()
        }
    }

    /// Tart serves Linux jobs when its base image is a Linux one.
    var tartLinuxOn: Bool { TartBaseImage.isLinux(tartBaseImage) }

    /// Set while tart's main base image is Linux and the fleet still
    /// advertises `macos`: macOS jobs would be routed to a Linux VM and fail
    /// there. This warning does not apply when you use named images with
    /// distinct labels — a Linux-named image strips the fleet's `macos` label
    /// automatically, so macOS and Linux Tart VMs can share one fleet.
    var tartLinuxLabelWarning: String? {
        guard tartLinuxOn, fleetLabels.contains(where: { $0.lowercased() == "macos" }) else { return nil }
        return String(
            localized:
                "Your fleet labels include “macos”, so macOS jobs would be sent to this Linux VM. In config.yaml, remove “macos” from labels (add “linux” if jobs ask for it).",
            bundle: .l10n,
            comment: "Warning under the Tart (Linux VM) row; macos, linux and config.yaml are literal names")

    }

    /// The "Tart (Linux VM)" checkbox: on starts from the default Linux
    /// image; off drops the key, returning tart to the macOS default.
    func setTartLinux(_ on: Bool) {
        guard tartInstalled || !on else { return }
        saveBaseImage(on ? TartBaseImage.defaultLinuxReference : nil, for: .tart)
    }

    func saveBaseImage(_ value: String?, for runtime: RuntimeID) {
        do {
            try GeneralConfigEditor.setBaseImage(value, for: runtime, at: configURL)
            refreshBaseImages()
            onChanged?()
            installs.busyLine = Line(
                text: String(
                    localized: "Base image saved. Rebuild the image for it to take effect.", bundle: .l10n,
                    comment: "This Mac form status after choosing a base image"))
        } catch {
            installs.busyLine = .notSaved(error)
            refreshBaseImages()
        }
    }
}
