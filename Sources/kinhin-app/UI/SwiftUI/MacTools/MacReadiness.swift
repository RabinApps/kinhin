import Foundation

/// The "is this Mac ready to run jobs" rule, as a value: tart with its base
/// image, or an enabled Linux runtime (Docker / Apple container) that is
/// actually installed. Tart is optional; a Linux-only Mac is a valid setup.
struct MacReadiness: Equatable {
    /// tart is installed and its base image is prepared.
    var tartReady = false
    var containerEnabled = false
    var containerInstalled = false
    var dockerEnabled = false
    var dockerInstalled = false

    /// Enabled *and* installed Linux runtimes, by display name.
    var activeLinuxRuntimes: [String] {
        var active: [String] = []
        if containerEnabled, containerInstalled {
            active.append(
                String(
                    localized: "Apple container", bundle: .l10n,
                    comment: "Runtime name used inside sentences (Linux runtime list)"))
        }
        if dockerEnabled, dockerInstalled {
            active.append(
                String(
                    localized: "Docker", bundle: .l10n,
                    comment: "Runtime name used inside sentences (Linux runtime list)"))
        }
        return active
    }

    var isReady: Bool { tartReady || !activeLinuxRuntimes.isEmpty }

    /// Plain-language summary of what jobs can run here (for the final step).
    var runsOnDescription: String {
        let linux = activeLinuxRuntimes.formatted(.list(type: .and, width: .narrow))
        switch (tartReady, activeLinuxRuntimes.isEmpty) {
        case (true, true):
            return String(localized: "macOS jobs (tart)", bundle: .l10n, comment: "Setup summary of what jobs can run")
        case (true, false):
            return String(
                localized: "macOS jobs (tart) and Linux jobs (\(linux))", bundle: .l10n,
                comment: "Setup summary of what jobs can run; %@ lists Linux runtimes")
        case (false, false):
            return String(
                localized: "Linux jobs only (\(linux)) — macOS jobs need tart, which isn't set up", bundle: .l10n,
                comment: "Setup summary of what jobs can run; %@ lists Linux runtimes")
        case (false, true):
            return String(localized: "nothing yet", bundle: .l10n, comment: "Setup summary of what jobs can run")
        }
    }
}
