import Foundation

// MARK: - Schema version and unknown keys

extension ConfigLoader {
    /// The config schema this build understands. `version:` is optional in the
    /// file (absent = 1). A file that declares a newer version is read
    /// leniently: keys this build does not know are logged and ignored instead
    /// of rejected, so an older kinhin can still run a config written for a
    /// newer one.
    public static let currentVersion = 1

    /// Validates `version:` and then rejects (or, for a newer schema, logs)
    /// every key the schema does not know, with a "did you mean" suggestion.
    static func checkSchema(_ partial: PartialConfig, yaml: String) throws {
        let version = partial.version ?? 1
        guard version >= 1 else {
            throw ConfigError.invalid("version must be a positive integer (the current schema is \(currentVersion))")
        }
        let unknown = try ConfigSchema.unknownKeys(in: yaml)
        guard !unknown.isEmpty else { return }
        if version > currentVersion {
            for key in unknown {
                Log.warn(
                    "config",
                    "\(key.message) (config version \(version) is newer than this kinhin's \(currentVersion); ignoring)"
                )
            }
            return
        }
        let detail = unknown.map(\.message).joined(separator: "; ")
        throw ConfigError.invalid(
            "\(detail). Unknown keys are rejected so a typo cannot silently fall back to a default; "
                + "remove the key, or prefix a top-level note with 'x-'")
    }
}
