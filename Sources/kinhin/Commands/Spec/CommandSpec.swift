import Foundation

// The declarative description of the CLI: one `CommandSpec` per command (and
// subcommand), listing its names, flags and one-line summary. The resolver
// (`CommandResolver`), the top-level help (`helpText()`), the per-command
// `kinhin <cmd> --help` screens and the tests all read this one table, so a
// flag added here is parsed, validated, documented and pinned in one place.

/// A flag a command accepts.
struct FlagSpec: Equatable, Sendable {
    enum Arity: Equatable, Sendable {
        /// `--json`
        case none
        /// `--scope S`: the next argument is the value.
        case value
        /// `--from [REF]`: the next argument is the value unless it looks like a flag.
        case optionalValue
    }

    /// The canonical spelling first, then aliases (`["--follow", "-f"]`).
    var names: [String]
    var arity: Arity = .none
    /// The value's name in usage lines (`FILE` in `--iso FILE`).
    var placeholder: String = ""
    var summary: String = ""
    /// Accepted but left out of usage and help (legacy spellings, discouraged forms).
    var hidden = false
    /// Flags sharing a group render as one `--a|--b|--c` row in help.
    var group: String?

    var name: String { names[0] }

    static func bool(
        _ name: String, aliases: [String] = [], _ summary: String = "", hidden: Bool = false, group: String? = nil
    ) -> FlagSpec {
        FlagSpec(names: [name] + aliases, arity: .none, summary: summary, hidden: hidden, group: group)
    }

    static func value(
        _ name: String, _ placeholder: String, aliases: [String] = [], _ summary: String = "", hidden: Bool = false
    ) -> FlagSpec {
        FlagSpec(
            names: [name] + aliases, arity: .value, placeholder: placeholder, summary: summary, hidden: hidden)
    }

    static func optionalValue(
        _ name: String, _ placeholder: String, aliases: [String] = [], _ summary: String = "", hidden: Bool = false
    ) -> FlagSpec {
        FlagSpec(
            names: [name] + aliases, arity: .optionalValue, placeholder: placeholder, summary: summary,
            hidden: hidden)
    }

    /// `--scope S` / `[--json]` rendering for usage lines.
    var usageForm: String {
        switch arity {
        case .none: return name
        case .value: return "\(name) \(placeholder)"
        case .optionalValue: return "\(name) [\(placeholder)]"
        }
    }
}

/// The section of the top-level help a command is listed under.
enum HelpGroup: Int, CaseIterable, Sendable {
    case setup
    case images
    case running
    case workflows
    case other

    var title: String {
        switch self {
        case .setup: return "SETUP"
        case .images: return "IMAGES AND TOOLCHAINS"
        case .running: return "RUNNING"
        case .workflows: return "WORKFLOWS"
        case .other: return "OTHER"
        }
    }
}

struct CommandSpec: Equatable, Sendable {
    /// The spelling shown in help (`image`, and `list` for a subcommand).
    var name: String
    /// Other spellings that keep working but are not advertised (`ls`, `pipelines`, `--version`).
    var aliases: [String] = []
    /// What the command routes to. A subcommand without its own meaning inherits its parent's.
    var command: CLICommand
    var group: HelpGroup = .other
    /// One line, at most ~70 characters: it sits beside the command in the overview.
    var summary: String
    /// Operands in usage lines (`<name>…`, `[VM]`).
    var positionals: String = ""
    var flags: [FlagSpec] = []
    var subcommands: [CommandSpec] = []
    /// The subcommand a bare invocation means (`auth` is `auth set`, `image` is `image prepare`).
    var defaultSubcommand: String?
    /// Left out of the overview and the suggestion pool (legacy top-level spellings).
    var hidden = false
    /// Extra paragraphs for `kinhin <cmd> --help`.
    var details: [String] = []
    /// A repo path (`docs/runtimes.md`) the long explanation lives in.
    var docs: String?
    /// Replaces the generated usage line(s), for grammars the generator cannot express.
    var usage: [String] = []
    /// A bare invocation (no subcommand) is a usage error instead of running the command itself.
    var requiresSubcommand = false

    var visibleSubcommands: [CommandSpec] { subcommands.filter { !$0.hidden } }

    /// Whether `token` names this command (canonical name or alias).
    func matches(_ token: String) -> Bool {
        name == token || aliases.contains(token)
    }
}

extension CommandSpec {
    /// A command whose flags/positionals all live on the one spec.
    func subcommand(named token: String) -> CommandSpec? {
        subcommands.first { $0.matches(token) }
    }

    /// Flags a spec accepts itself (not its parents').
    func flag(matching token: String) -> FlagSpec? {
        flags.first { $0.names.contains(token) }
    }
}
