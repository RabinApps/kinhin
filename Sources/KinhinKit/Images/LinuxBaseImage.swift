import Foundation

/// The base image a Linux runner image (Apple container or Docker) is baked
/// on top of. kinhin's install scripts use `apt-get`, so bases must be
/// Debian- or Ubuntu-based.
public enum LinuxBaseImage {
    public static let defaultReference = "ubuntu:24.04"

    /// Images the install scripts are exercised against, for the pickers.
    public static let curated: [(title: String, reference: String)] = [
        ("Ubuntu 24.04", "ubuntu:24.04"),
        ("Ubuntu 22.04", "ubuntu:22.04"),
        ("Debian 12", "debian:12"),
    ]

    /// Which base to use: an explicit override (a CLI flag) wins, then the
    /// config value, then the default.
    public static func resolve(configured: String?, flagOverride: String? = nil) -> String {
        for candidate in [flagOverride, configured] {
            if let value = candidate?.trimmingCharacters(in: .whitespaces), !value.isEmpty { return value }
        }
        return defaultReference
    }

    /// Why `reference` can't be used as a base, or nil when it's acceptable.
    /// The value ends up in a `container run`/`docker run` argv, so anything
    /// that could be read as an option or that splits into several arguments
    /// is rejected.
    public static func problem(with reference: String) -> String? {
        if reference.isEmpty { return "must not be empty" }
        if reference.hasPrefix("-") { return "must not start with '-'" }
        if reference.contains(where: \.isWhitespace) { return "must not contain spaces" }
        return nil
    }
}
