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

    /// `kinhin config migrate`: translates removed legacy keys to the current
    /// schema. Prints the result (notes and warnings on stderr so stdout stays
    /// pipeable); `--write` keeps the original as `<config>.bak` and replaces it.
    static func migrate(_ args: [String], configURL: URL = Paths.config) throws {
        let migration = try ConfigMigrator.migrate(fileAt: configURL)
        for change in migration.changes { printError("migrated: \(change)") }
        for warning in migration.warnings { printError("warning: \(warning)") }
        if migration.isNoop {
            printError("config already uses the current schema; nothing to migrate")
            return
        }
        guard args.contains("--write") else {
            print(migration.yaml, terminator: migration.yaml.hasSuffix("\n") ? "" : "\n")
            return
        }
        let backup = configURL.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: configURL, to: backup)
        try migration.yaml.write(to: configURL, atomically: true, encoding: .utf8)
        print("wrote \(configURL.path) (original kept at \(backup.path))")
    }

    /// `kinhin config validate`: parses and validates the config file without
    /// starting anything or writing to disk, so a hand edit can be checked before
    /// the fleet (or daemon) reloads it. Throws the loader's `ConfigError` (exit 3).
    /// Returns the one-line summary the command prints.
    static func validate(configURL: URL = Paths.config) throws -> String {
        let document = try validated(configURL: configURL)
        let accounts = document.accounts.map { "\($0.name) (\($0.forge), \($0.scope))" }.joined(separator: ", ")
        return "config OK: \(document.path): \(document.accounts.count) account(s) — \(accounts); "
            + "labels \(document.labels.joined(separator: ",")); \(document.runtimeRoutes) runtime route(s)"
    }

    /// The machine-readable `config validate` contract: the parsed facts on
    /// success, the failure reason in `error` when not. Shared by the prose
    /// path (which throws) and `--json` (which prints either way, then exits 3).
    struct ValidationDocument: Codable, Equatable {
        var valid: Bool
        var path: String
        var error: String?
        var accounts: [Account]
        var labels: [String]
        var runtimeRoutes: Int

        struct Account: Codable, Equatable {
            var name: String
            var forge: String
            var scope: String
        }
    }

    /// Parses and validates without printing, reporting failure *in* the
    /// document instead of throwing, so `--json` still emits output before
    /// the exit code.
    static func validationDocument(configURL: URL = Paths.config) -> ValidationDocument {
        do {
            return try validated(configURL: configURL)
        } catch {
            return ValidationDocument(
                valid: false, path: configURL.path, error: error.localizedDescription,
                accounts: [], labels: [], runtimeRoutes: 0)
        }
    }

    /// The shared throwing core: the loader's error for an unusable file,
    /// `ConfigError` when it parses but has no accounts yet.
    private static func validated(configURL: URL) throws -> ValidationDocument {
        let config = try ConfigLoader.load(from: configURL)
        guard ConfigLoader.hasAnyForge(config) else {
            throw ConfigError.invalid(
                "\(configURL.path) has no accounts yet; add one (accounts: [{name: github, forge: github, scope: owner/name}]) or run `kinhin auth add`"
            )
        }
        let accounts = config.accounts.map {
            ValidationDocument.Account(name: $0.name, forge: $0.forge.rawValue, scope: $0.scope)
        }
        return ValidationDocument(
            valid: true,
            path: configURL.path,
            error: nil,
            accounts: accounts,
            labels: config.labels,
            runtimeRoutes: config.runtimes?.routes.count ?? 0
        )
    }

    /// The whole `config validate` command: the summary line, or — with
    /// `--json` — the document on stdout either way, then exit 3 when invalid
    /// (the same classification the prose path gets by throwing).
    static func runValidate(_ args: [String]) throws {
        guard args.contains("--json") else {
            print(try validate())
            return
        }
        let document = validationDocument()
        try emitJSON(document)
        guard document.valid else { exit(CLIExit.config.rawValue) }
    }
}
