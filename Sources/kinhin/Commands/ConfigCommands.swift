import Foundation
import KinhinKit

/// Config-file management (the `config init` command).
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
}
