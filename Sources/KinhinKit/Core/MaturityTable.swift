import Foundation

/// How much real-world testing a forge or runtime has had.
public enum Maturity: String, Sendable, Equatable {
    /// Exercised end to end against the real service by the maintainer.
    case liveTested
    /// Implemented and covered by unit and contract tests, but not yet run
    /// against the real service or runtime.
    case untested

    public var isUntested: Bool { self == .untested }
}

/// The one table of what is live-tested. The app's "untested" badges and the
/// docs (`docs/app.md`, via `scripts/docs-sync.sh`) both read it, so promoting
/// a forge or runtime means editing the two lists below and nothing else.
///
/// Keep each list on a single line: the docs generator parses them.
public enum MaturityTable {
    /// Forges run against the real service.
    public static let liveTestedForges: [ForgeID] = [.github, .gitea, .forgejo]
    /// Runtimes run for real. `tart` here means macOS VMs; Tart serving Linux VMs is `tartLinux`.
    public static let liveTestedRuntimes: [RuntimeID] = [.tart, .appleContainer]
    /// Tart serving Linux VMs (a Linux base image) has not been live-tested.
    public static let tartLinux: Maturity = .untested

    public static func maturity(of forge: ForgeID) -> Maturity {
        liveTestedForges.contains(forge) ? .liveTested : .untested
    }

    public static func maturity(of runtime: RuntimeID) -> Maturity {
        liveTestedRuntimes.contains(runtime) ? .liveTested : .untested
    }
}
