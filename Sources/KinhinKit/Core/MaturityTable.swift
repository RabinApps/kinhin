import Foundation

/// How much real-world testing a forge or runtime has had.
public enum Maturity: String, Sendable, Equatable {
    /// Exercised end to end against the real service by the maintainer.
    case liveTested
    /// Implemented and covered by unit and contract tests, but not yet run
    /// against the real service or runtime.
    case untested
    /// Has run real jobs against the real service, but not in the maintainer's
    /// own end-to-end lane: reported by a user, so less settled than `liveTested`.
    case experimental

    public var isUntested: Bool { self == .untested }
    public var isExperimental: Bool { self == .experimental }
}

/// The one table of what is live-tested. The app's "untested" and "experimental" badges and the
/// docs (`docs/app.md`, via `scripts/docs-sync.sh`) both read it, so promoting
/// a forge or runtime means editing the two lists below and nothing else.
///
/// Keep each list on a single line: the docs generator parses them.
public enum MaturityTable {
    /// Forges run against the real service.
    public static let liveTestedForges: [ForgeID] = [.github, .gitea, .forgejo, .gitlab]
    /// Forges that have run real jobs for a user but have not passed the project's own live lane.
    public static let experimentalForges: [ForgeID] = [.azuredevops]
    /// Runtimes run for real. `tart` here means macOS VMs; Tart serving Linux VMs is `tartLinux`.
    public static let liveTestedRuntimes: [RuntimeID] = [.tart, .appleContainer, .docker, .host]
    /// Tart serving Linux VMs (a Linux base image), run for real by the end-to-end suite.
    public static let tartLinux: Maturity = .liveTested

    public static func maturity(of forge: ForgeID) -> Maturity {
        if liveTestedForges.contains(forge) { return .liveTested }
        return experimentalForges.contains(forge) ? .experimental : .untested
    }

    public static func maturity(of runtime: RuntimeID) -> Maturity {
        liveTestedRuntimes.contains(runtime) ? .liveTested : .untested
    }
}
