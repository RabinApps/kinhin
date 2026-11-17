import Foundation

// MARK: - min_idle (idle registered runners per pool and per Tart image)

extension ConfigLoader {
    /// The `min_idle` floors across sections, checked once every section is parsed: each per-key value is already
    /// known to be `>= 0`. The rules live in `MinIdleValidation`, which the app also calls to show errors before
    /// saving; the first one it reports fails the load.
    static func validateMinIdle(_ cfg: KinhinConfig) throws {
        if let issue = MinIdleValidation.issues(for: cfg).first { throw ConfigError.invalid(issue.message) }
    }
}
