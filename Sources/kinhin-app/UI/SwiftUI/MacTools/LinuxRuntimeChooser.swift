import Foundation
import KinhinKit

/// The three Linux runtimes a repo's Linux jobs can run on, and the one the
/// user picks from the "This Mac" form. Mirrors `docs/runtimes.md` choosing-
/// a-linux-runtime: each option carries its own per-runtime prerequisites, so
/// the sheet only offers what this Mac can actually run, and the "why" text is
/// the comparison from the docs (VM-grade isolation / density / amd64 / needs /
/// best-for), not a paraphrase the reader would have to trust.
enum LinuxRuntimeSetup: Sendable, CaseIterable {
    case appleContainer
    case docker
    case tartLinux

    var id: String {
        switch self {
        case .appleContainer: return "appleContainer"
        case .docker: return "docker"
        case .tartLinux: return "tartLinux"
        }
    }

    var displayName: String {
        switch self {
        case .appleContainer:
            return String(localized: "Apple container", bundle: .l10n, comment: "Linux runtime option name")
        case .docker: return String(localized: "Docker", bundle: .l10n, comment: "Linux runtime option name")
        case .tartLinux:
            return String(localized: "Tart (Linux VM)", bundle: .l10n, comment: "Linux runtime option name")
        }
    }

    /// How much real-world testing the option has had (`MaturityTable`).
    var maturity: Maturity {
        switch self {
        case .appleContainer: return MaturityTable.maturity(of: .appleContainer)
        case .docker: return MaturityTable.maturity(of: .docker)
        case .tartLinux: return MaturityTable.tartLinux
        }
    }

    /// The installable tool behind the option.
    var tool: InstallableTool? {
        switch self {
        case .appleContainer: return .appleContainer
        case .docker: return .docker
        case .tartLinux: return .tart
        }
    }

    /// Per-runtime prerequisites the reader can act on. Mirrors the docs:
    /// apple/container needs the container CLI; Docker needs a Docker provider;
    /// Tart (Linux VM) needs tart.
    var prerequisite: String {
        switch self {
        case .appleContainer:
            return String(
                localized: "Apple container CLI (brew install container)", bundle: .l10n,
                comment: "Linux runtime prerequisite; the brew command stays verbatim")
        case .docker:
            return String(
                localized: "Docker Desktop, OrbStack or colima", bundle: .l10n, comment: "Linux runtime prerequisite")
        case .tartLinux:
            return String(localized: "tart (for macOS VMs too)", bundle: .l10n, comment: "Linux runtime prerequisite")
        }
    }

    /// One-line comparison row from the docs, used as the option's "why" line.
    var summary: String {
        switch self {
        case .appleContainer:
            return
                String(
                    localized:
                        "VM-grade isolation, no daemon, high density, 8 GB/instance — Debian/Ubuntu-based image only, no amd64, beta.",
                    bundle: .l10n, comment: "Linux runtime comparison summary")
        case .docker:
            return
                String(
                    localized:
                        "Highest density if a Docker provider already runs; amd64 via emulation with JIT/Go/Java/.NET caveats; shared kernel.",
                    bundle: .l10n, comment: "Linux runtime comparison summary")
        case .tartLinux:
            return
                String(
                    localized:
                        "Full control: your distro, kernel modules, long sudo; lowest density, 50 GB/instance, needs an ISO or published image.",
                    bundle: .l10n, comment: "Linux runtime comparison summary")
        }
    }

    /// Options worth showing on this Mac, with any "limited" caveat folded into
    /// the option's detail (same shape HostRequirements.offeredOptions already builds).
    static func offeredOptions(on host: HostFacts) -> [LinuxRuntimeSetup] {
        allCases.filter { unavailableReason(for: $0, on: host) == nil }
    }

    /// Why the option cannot run here, or nil when at least one install path works.
    static func unavailableReason(for option: LinuxRuntimeSetup, on host: HostFacts) -> String? {
        switch option {
        case .appleContainer:
            return HostRequirements.blockingReason(for: .appleContainer, on: host)
        case .docker:
            return HostRequirements.blockingReason(for: .docker, on: host)
        case .tartLinux:
            // tart is supported on every Mac kinhin runs on; the only blocker
            // is a host that kinhin itself excludes.
            return HostRequirements.blockingReason(for: .tart, on: host)
        }
    }

    /// The sheet's confirm payload: the option the user chose, plus the install
    /// method they picked (nil = the best available one).
    struct Offer: Identifiable {
        let id: String
        let tool: InstallableTool?
        let method: String?
        let onConfirm: (Offer?) -> Void

        init(
            tool: InstallableTool?,
            options: [LinuxRuntimeSetup],
            onConfirm: @escaping (Offer?) -> Void
        ) {
            self.id = UUID().uuidString
            self.tool = tool
            self.method = nil
            self.onConfirm = onConfirm
        }

        static func == (lhs: Offer, rhs: Offer) -> Bool { lhs.id == rhs.id }
    }

    static var allRuntimes: [LinuxRuntimeSetup] { allCases }
}

/// What the "Set up Linux jobs…" button offers on a given Mac.
enum LinuxRuntimeChooser {
    /// The sheet's inputs, or nil when no Linux runtime can run here (the form
    /// already says why).
    static func offer(on host: HostFacts, onConfirm: @escaping (LinuxRuntimeSetup.Offer?) -> Void)
        -> LinuxRuntimeSetup.Offer?
    {
        let options = LinuxRuntimeSetup.offeredOptions(on: host)
        guard !options.isEmpty else { return nil }
        return LinuxRuntimeSetup.Offer(tool: nil, options: options, onConfirm: onConfirm)
    }
}
