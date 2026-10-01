import Foundation

/// The operating system of the image being baked. Detected by running
/// `uname -s` in the scratch VM over SSH (`Darwin` → macOS, anything else
/// → Linux), so a tart Linux base VM gets the Linux agent binaries and the
/// Linux toolchain path instead of the macOS ones. Overridable in
/// `ImagePreparer.Options.guestOS` for tests and as an escape hatch.
public enum GuestOS: String, Sendable {
    case macOS
    case linux

    /// The ToolchainPlatform matching this guest OS.
    var toolchainPlatform: ToolchainPlatform {
        self == .macOS ? .macOS : .linux
    }

    /// The guest-side path of the shared toolchain cache for this OS:
    /// macOS guests see the virtiofs share, Linux guests (a future tart
    /// virtiofs share) the container-style mount path.
    var toolchainMountPath: String {
        self == .macOS ? ToolchainCacheMount.guestPath : ToolchainCacheMount.linuxGuestPath
    }

    /// Parses the stdout of `uname -s`.
    static func parse(unameOutput: String) -> GuestOS? {
        switch unameOutput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "darwin": return .macOS
        case "linux": return .linux
        default: return nil
        }
    }

    /// The `uname -s` detection probe run in the scratch VM.
    static let probeScript = "uname -s"

    // MARK: - Bake scripts

    /// The base-image tweak script for this guest. macOS disables sleep and
    /// makes sure Remote Login is on; a Linux guest needs neither (tart
    /// clones of it get SSH from the base image's own setup, and there is
    /// no power management to defeat).
    func prepareScript() -> String {
        switch self {
        case .macOS:
            return RunnerBootstrap.prepareScript()
        case .linux:
            return """
                set -euo pipefail

                # Linux guest: the macOS tweaks (pmset sleep disable, Remote Login)
                # do not apply — the base image already has SSH (the curated images
                # ship admin/admin + Tart's key) and there is no power management
                # to defeat.

                echo "base image prepared (linux guest)"
                """
        }
    }

    /// The managed-toolchains script for this guest (brew for macOS, apt +
    /// mise for Linux). The Linux variant is rendered for a non-root admin
    /// user (a tart VM guest), unlike the container bake which runs as root.
    func managedToolchainsScript(selection: ManagedToolchainSelection, mountPath: String?) -> String {
        switch self {
        case .macOS:
            return RunnerBootstrap.managedToolchainsInstallScript(selection: selection, mountPath: mountPath)
        case .linux:
            return RunnerBootstrap.linuxManagedToolchainsInstallScript(
                selection: selection, mountPath: mountPath, runsAsRoot: false)
        }
    }
}
