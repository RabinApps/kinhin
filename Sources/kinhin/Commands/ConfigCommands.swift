import Foundation
import KinhinKit

/// Config-file management (`config init`, `config validate`).
enum ConfigCommands {
    /// `configURL` is injectable so tests can exercise the write/exists/force
    /// matrix against a scratch directory.
    static func configInit(_ args: [String], configURL: URL = Paths.config) throws {
        let force = args.contains("--force")
        if FileManager.default.fileExists(atPath: configURL.path), !force {
            print("config already exists at \(configURL.path) (use --force to overwrite)")
        } else {
            try ConfigLoader.template().write(toFile: configURL.path, atomically: true, encoding: .utf8)
            print("wrote \(configURL.path)")
            print("next: set your repo in \(configURL.path), then `kinhin auth set`")
        }
    }

    /// `kinhin config validate`: parses and validates the config file without
    /// starting anything or writing to disk, so a hand edit can be checked before
    /// the fleet (or daemon) reloads it. Throws the loader's `ConfigError` (exit 3).
    /// Returns the one-line summary the command prints.
    static func validate(configURL: URL = Paths.config) throws -> String {
        let config = try ConfigLoader.load(from: configURL)
        guard ConfigLoader.hasAnyForge(config) else {
            throw ConfigError.invalid(
                "\(configURL.path) has no accounts yet; add one (accounts: [{name: github, forge: github, scope: owner/name}]) or run `kinhin auth add`"
            )
        }
        let accounts = config.accounts.map { "\($0.name) (\($0.forge.rawValue), \($0.scope))" }.joined(separator: ", ")
        let routes = config.runtimes?.routes.count ?? 0
        return "config OK: \(configURL.path): \(config.accounts.count) account(s) — \(accounts); "
            + "labels \(config.labels.joined(separator: ",")); \(routes) runtime route(s)"
    }
}
