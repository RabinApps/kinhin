import Foundation
import KinhinKit

/// Config-file management (`config init`, `validate`, `migrate`, `export`, `import`).
enum ConfigCommands {
    /// `configURL` is injectable so tests can exercise the write/exists/force
    /// matrix against a scratch directory.
    static func configInit(_ args: [String], configURL: URL = Paths.config) throws {
        let force = args.contains("--force")
        if FileManager.default.fileExists(atPath: configURL.path), !force {
            print("config already exists at \(configURL.path) (use --force to overwrite)")
        } else {
            // A first run has no support directory yet, and the config stays private like every other support file.
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try Paths.writePrivateFile(Data(ConfigLoader.template().utf8), to: configURL)
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
        // No earlier backup is the usual case; one that cannot go makes copyItem throw below.
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
    /// (the same classification the prose path gets by throwing). `FILE`
    /// validates that config instead of this Mac's default one.
    static func runValidate(_ args: [String]) throws {
        let files = operands(in: args)
        guard files.count <= 1 else {
            throw CLIError(
                "usage: kinhin config validate [FILE] (at most one config; `--` accepts names starting with `-`)",
                exit: .usage)
        }
        let configURL = files.first.map { URL(fileURLWithPath: $0) } ?? Paths.config
        guard args.contains("--json") else {
            print(try validate(configURL: configURL))
            return
        }
        let document = validationDocument(configURL: configURL)
        try emitJSON(document)
        guard document.valid else { exit(CLIExit.config.rawValue) }
    }

    // MARK: - Moving a config to another Mac

    /// `kinhin config export [FILE|-]`: the validated config with a header, to
    /// stdout (no FILE or `-`) or a private file. Refuses to overwrite FILE
    /// without --force.
    static func export(_ args: [String], configURL: URL = Paths.config) throws {
        let text = try ConfigTransfer.export(configURL: configURL, host: ProcessInfo.processInfo.hostName)
        guard let path = positional(args), path != "-" else {
            print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
            return
        }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path), !args.contains("--force") {
            throw CLIError("\(url.path) already exists (use --force to overwrite)", exit: .usage)
        }
        try Paths.writePrivateFile(Data(text.utf8), to: url)
        print("wrote \(url.path) — tokens are not included")
        print("next: on the other Mac run `kinhin config import \(url.lastPathComponent)`")
    }

    /// `kinhin config import FILE|- [--yes]`: validates the file, then writes it
    /// when there is no config yet, or replaces the current one (kept as
    /// config.yaml.bak) with --yes. Without --yes an existing config is only
    /// compared, never touched.
    static func importConfig(
        _ args: [String], configURL: URL = Paths.config,
        readStdin: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() },
        daemonRunning: () -> Bool = { RPCClient.isDaemonAlive() }
    ) throws {
        guard let path = positional(args) else {
            throw CLIError("usage: kinhin config import FILE [--yes] (FILE - reads stdin)", exit: .usage)
        }
        let data: Data
        if path == "-" {
            data = readStdin()
        } else {
            let url = URL(fileURLWithPath: path)
            guard let read = FileManager.default.contents(atPath: url.path) else {
                throw CLIError("cannot read \(url.path)", exit: .usage)
            }
            data = read
        }
        let plan = try ConfigTransfer.plan(incoming: String(decoding: data, as: UTF8.self), configURL: configURL)
        let apply = !plan.unchanged && (!plan.replacesExisting || args.contains("--yes"))
        if apply { try ConfigTransfer.apply(plan) }
        for line in importReport(plan, applied: apply, daemonRunning: apply && daemonRunning()) { print(line) }
    }

    /// What `config import` prints: what happened, then what this Mac still needs.
    static func importReport(_ plan: ConfigTransfer.ImportPlan, applied: Bool, daemonRunning: Bool) -> [String] {
        var lines: [String] = []
        if plan.unchanged {
            lines.append("\(plan.configURL.path) already matches; nothing to import")
        } else if applied {
            lines.append("imported into \(plan.configURL.path)")
            if plan.replacesExisting { lines.append("previous config kept at \(plan.backupURL.path)") }
        } else {
            lines.append("valid config; it would replace \(plan.configURL.path)")
            let backup = plan.backupURL.lastPathComponent
            lines.append("run again with --yes to replace it (the current one is kept as \(backup))")
        }
        for warning in plan.warnings { lines.append("warning: \(warning)") }
        let missing = plan.accounts.filter { !$0.tokenStored }
        if !missing.isEmpty {
            lines.append("tokens to store on this Mac:")
            for account in missing {
                lines.append("  kinhin auth set --account \(account.name)   (\(account.forge.rawValue))")
            }
        }
        if applied || plan.unchanged {
            lines.append("next: `kinhin setup status` shows the images to prepare on this Mac")
        }
        if daemonRunning {
            lines.append("the running fleet uses the new config after you restart the app or the daemon")
        }
        return lines
    }

    /// The first argument that is not a flag.
    private static func positional(_ args: [String]) -> String? {
        args.first { $0 == "-" || !$0.hasPrefix("-") }
    }

    /// The config subcommand's file operands. `--` ends the flags, so
    /// everything after it counts (a filename starting with `-`), and tokens
    /// before it that are not flags are operands too — a marker does not
    /// erase them, or `broken.yaml --` would validate the default config.
    static func operands(in args: [String]) -> [String] {
        guard let marker = args.firstIndex(of: "--") else {
            return args.compactMap { $0 == "-" || !$0.hasPrefix("-") ? $0 : nil }
        }
        return args[..<marker].compactMap { $0 == "-" || !$0.hasPrefix("-") ? $0 : nil }
            + args[(marker + 1)...]
    }
}
