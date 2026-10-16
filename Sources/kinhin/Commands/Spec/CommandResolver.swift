import Foundation

/// A parsed command line: which command, which subcommand, and the operands
/// left for the command body. Produced by `CommandResolver.resolve`, which has
/// already rejected unknown commands, subcommands and flags.
struct Invocation: Equatable, Sendable {
    /// Canonical names, aliases resolved: `["image", "list"]` for `image ls`.
    var path: [String]
    var command: CLICommand
    /// The whole command line, with a quoted two-word head (`"image digest"`) split.
    var args: [String]
    /// What follows the command path (`image list --json` leaves `["--json"]`).
    var rest: [String]
    var wantsHelp: Bool
    /// The spec `--help` documents: the deepest command the line names.
    var helpSpec: CommandSpec
    var helpPath: [String]

    /// The canonical subcommand (`prune` in `toolchains prune`), if one was named.
    var subcommand: String? { path.dropFirst().first }

    var json: Bool { rest.contains("--json") }
    var quiet: Bool { rest.contains("--quiet") || rest.contains("-q") }
}

enum CommandResolver {
    /// Splits a quoted two-word head (`kinhin "image digest" ref`) into tokens.
    static func normalized(_ args: [String]) -> [String] {
        guard let first = args.first, first.contains(" ") else { return args }
        return first.split(separator: " ").map(String.init) + args.dropFirst()
    }

    // MARK: - Lenient lookup

    /// The command a line routes to, ignoring unknown subcommands and flags
    /// (the historical head-token dispatch). Nil for an unknown command.
    static func lookup(_ args: [String]) -> CLICommand? {
        let argv = normalized(args)
        guard let head = argv.first else { return .help }
        guard var spec = CommandCatalog.topLevel(head) else { return nil }
        var index = 1
        while index < argv.count, let sub = spec.subcommand(named: argv[index]) {
            spec = sub
            index += 1
        }
        return spec.command
    }

    // MARK: - Strict resolution

    /// Resolves and validates a command line. Throws a `.usage` `CLIError`
    /// (with a usage line and a "did you mean") for anything undeclared.
    static func resolve(_ args: [String]) throws -> Invocation {
        let argv = normalized(args)
        guard let head = argv.first else {
            guard let help = CommandCatalog.topLevel("help") else {
                preconditionFailure("CommandCatalog must declare the help command")
            }
            return Invocation(
                path: ["help"], command: .help, args: argv, rest: [], wantsHelp: false, helpSpec: help,
                helpPath: ["help"])
        }
        guard let top = CommandCatalog.topLevel(head) else {
            throw unknownCommand(head)
        }

        // Walk subcommands: the first non-flag token after a spec that has
        // subcommands (and takes no operands of its own) must name one.
        var spec = top
        var path = [top.name]
        var index = 1
        while !spec.subcommands.isEmpty, index < argv.count, !argv[index].hasPrefix("-") {
            guard let sub = spec.subcommand(named: argv[index]) else {
                if spec.positionals.isEmpty { throw unknownSubcommand(argv[index], of: spec, path: path) }
                break
            }
            spec = sub
            path.append(sub.name)
            index += 1
        }

        // The flags in force: the leaf's own, plus the default subcommand's
        // when the line stopped at a parent (`auth --gitea` is `auth set`).
        var flagSpecs = spec.flags
        var effectiveCommand = spec.command
        if !spec.subcommands.isEmpty, let defaultName = spec.defaultSubcommand,
            let defaultSub = spec.subcommand(named: defaultName)
        {
            flagSpecs += defaultSub.flags
            effectiveCommand = defaultSub.command
        }

        let wantsHelp = try scanFlags(Array(argv.dropFirst(index)), flags: flagSpecs, spec: spec, path: path)
        if !wantsHelp, spec.requiresSubcommand, !spec.subcommands.isEmpty,
            index >= argv.count || argv[index].hasPrefix("-")
        {
            throw missingSubcommand(of: spec, path: path)
        }
        return Invocation(
            path: path, command: effectiveCommand, args: argv, rest: Array(argv.dropFirst(index)),
            wantsHelp: wantsHelp, helpSpec: spec, helpPath: path)
    }

    /// Validates the tokens after the command path against `flags`; true
    /// when `--help`/`-h` was among them.
    private static func scanFlags(
        _ tokens: [String], flags: [FlagSpec], spec: CommandSpec, path: [String]
    ) throws -> Bool {
        var wantsHelp = false
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if token == "--" { break }
            guard token.hasPrefix("-"), token.count > 1, Double(token) == nil else { continue }
            if token == "--help" || token == "-h" {
                wantsHelp = true
                continue
            }
            let name = token.hasPrefix("--") ? String(token.prefix { $0 != "=" }) : token
            guard let flag = flags.first(where: { $0.names.contains(name) }) else {
                throw unknownFlag(token, spec: spec, path: path, flags: flags)
            }
            if name != token {
                throw CLIError(
                    "'\(name)' takes its value as a separate argument, not '\(token)'"
                        + usageSuffix(spec: spec, path: path),
                    exit: .usage)
            }
            switch flag.arity {
            case .none: break
            case .value:
                guard index < tokens.count else {
                    throw CLIError(
                        "option '\(name)' needs a value (\(flag.placeholder))" + usageSuffix(spec: spec, path: path),
                        exit: .usage)
                }
                index += 1
            case .optionalValue:
                if index < tokens.count, !tokens[index].hasPrefix("-") { index += 1 }
            }
        }
        return wantsHelp
    }

    // MARK: - Errors

    private static func usageSuffix(spec: CommandSpec, path: [String]) -> String {
        let lines = HelpRenderer.usageLines(for: spec, path: path)
        let command = path.joined(separator: " ")
        return "\n" + lines.joined(separator: "\n") + "\nSee: kinhin \(command) --help"
    }

    private static func unknownCommand(_ token: String) -> CLIError {
        let pool = CommandCatalog.all.filter { !$0.hidden }.flatMap { [$0.name] + $0.aliases }
            .filter { !$0.hasPrefix("-") }
        var message = "unknown command '\(token)'"
        if let hint = suggestion(for: token, among: pool) { message += "; did you mean '\(hint)'?" }
        return CLIError(message + "\nRun `kinhin help` to list the commands.", exit: .usage)
    }

    private static func unknownSubcommand(_ token: String, of spec: CommandSpec, path: [String]) -> CLIError {
        let command = path.joined(separator: " ")
        let names = spec.visibleSubcommands.map(\.name)
        var message = "unknown subcommand '\(token)' for '\(command)'"
        if let hint = suggestion(for: token, among: names + spec.visibleSubcommands.flatMap(\.aliases)) {
            message += "; did you mean '\(hint)'?"
        }
        return CLIError(
            message + "\navailable: \(names.joined(separator: ", "))\nSee: kinhin \(command) --help", exit: .usage)
    }

    private static func missingSubcommand(of spec: CommandSpec, path: [String]) -> CLIError {
        let command = path.joined(separator: " ")
        let names = spec.visibleSubcommands.map(\.name)
        return CLIError(
            "'\(command)' needs a subcommand: \(names.joined(separator: ", "))\nSee: kinhin \(command) --help",
            exit: .usage)
    }

    private static func unknownFlag(_ token: String, spec: CommandSpec, path: [String], flags: [FlagSpec]) -> CLIError {
        let command = path.joined(separator: " ")
        let name = token.hasPrefix("--") ? String(token.prefix { $0 != "=" }) : token
        let pool = flags.filter { !$0.hidden }.flatMap(\.names)
        var message = "unknown option '\(name)' for '\(command)'"
        if let hint = suggestion(for: name, among: pool) { message += "; did you mean '\(hint)'?" }
        return CLIError(message + usageSuffix(spec: spec, path: path), exit: .usage)
    }

    // MARK: - Did you mean

    /// The closest candidate within a small edit distance, or a candidate the
    /// input is a prefix of. Nil when nothing is plausibly what was meant.
    static func suggestion(for input: String, among candidates: [String]) -> String? {
        let bare = input.drop { $0 == "-" }.lowercased()
        guard bare.count >= 2 else { return nil }
        var best: (candidate: String, distance: Int)?
        for candidate in candidates {
            let target = candidate.drop { $0 == "-" }.lowercased()
            var distance = editDistance(Array(bare), Array(target))
            if bare.count >= 3, target.hasPrefix(bare) { distance = min(distance, 1) }
            guard distance <= 2, distance < max(2, bare.count) else { continue }
            if distance < best?.distance ?? Int.max { best = (candidate, distance) }
        }
        return best?.candidate
    }

    /// Optimal-string-alignment distance (insert, delete, substitute, swap neighbours).
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
                }
            }
        }
        return table[a.count][b.count]
    }
}
