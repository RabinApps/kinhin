import Foundation

/// Renders the help screens from `CommandCatalog`: the top-level overview and
/// the per-command `kinhin <cmd> --help` page. Every line stays within
/// `columns`; long explanations live in the docs the page links to.
enum HelpRenderer {
    static let columns = 100
    static let docsURL = "https://github.com/RabinApps/kinhin/tree/main/docs"

    // MARK: - Overview

    private struct Row {
        var label: String
        var summary: String
    }

    /// The overview rows of one spec: its own row when it runs by itself,
    /// then one per visible subcommand (recursively).
    private static func rows(for spec: CommandSpec, path: [String]) -> [Row] {
        let here = path + [spec.name]
        let visible = spec.visibleSubcommands
        var result: [Row] = []
        let listsOwnRow = visible.isEmpty || (!spec.requiresSubcommand && spec.defaultSubcommand == nil)
        if listsOwnRow {
            let operands = spec.positionals.isEmpty ? "" : " " + spec.positionals
            result.append(Row(label: here.joined(separator: " ") + operands, summary: spec.summary))
        }
        for sub in visible { result += rows(for: sub, path: here) }
        return result
    }

    static func overview() -> String {
        var lines = [
            "kinhin — autoscaling CI runners on your Mac.",
            "Tart VMs run macOS jobs; apple/container, Docker or Tart Linux VMs run Linux jobs.",
            "Forges: GitHub Actions, GitLab CI/CD, Gitea, Forgejo (Buildkite, Azure, Bitbucket planned).",
            "",
        ]
        let visible = CommandCatalog.all.filter { !$0.hidden }
        let allRows = HelpGroup.allCases.map { group in
            (group, visible.filter { $0.group == group }.flatMap { rows(for: $0, path: []) })
        }
        let labelWidth = min(38, allRows.flatMap(\.1).map(\.label.count).max() ?? 0)
        lines += ["USAGE:"]
        lines += table(label: "kinhin", text: "Setup status and the next step", labelWidth: labelWidth)
        lines += table(label: "kinhin <command> [options]", text: "", labelWidth: labelWidth)
        lines += table(label: "kinhin <command> --help", text: "Options for one command", labelWidth: labelWidth)
        for (group, rows) in allRows where !rows.isEmpty {
            lines += ["", "\(group.title):"]
            for row in rows { lines += table(label: row.label, text: row.summary, labelWidth: labelWidth) }
        }
        lines += [
            "",
            "EXIT CODES:",
            "    0 ok    1 needs attention    2 usage error    3 config    4 runtime    5 auth",
            "",
            "Add --json for machine-readable output. Docs: \(docsURL)",
        ]
        return lines.joined(separator: "\n")
    }

    // MARK: - One command

    /// The `kinhin <cmd> --help` page.
    static func page(for spec: CommandSpec, path: [String]) -> String {
        var lines = ["kinhin \(path.joined(separator: " ")) — \(spec.summary)", ""]
        let usage = usageLines(for: spec, path: path)
        lines += usage
        for detail in spec.details {
            lines += [""] + wrap(detail, width: columns, indent: "")
        }
        let subs = spec.visibleSubcommands
        if !subs.isEmpty {
            lines += ["", "COMMANDS:"]
            let width = min(
                30, subs.map { $0.name.count + ($0.positionals.isEmpty ? 0 : $0.positionals.count + 1) }.max() ?? 0)
            for sub in subs {
                let label = sub.name + (sub.positionals.isEmpty ? "" : " " + sub.positionals)
                lines += table(label: label, text: sub.summary, labelWidth: width)
            }
        }
        let options = optionRows(spec.flags)
        if !options.isEmpty {
            lines += ["", "OPTIONS:"]
            let width = min(30, options.map(\.label.count).max() ?? 0)
            for option in options { lines += table(label: option.label, text: option.summary, labelWidth: width) }
        }
        var footer: [String] = []
        if let docs = spec.docs { footer.append("Details: \(docs)") }
        footer.append("Run `kinhin help` for every command.")
        lines += [""] + footer
        return lines.joined(separator: "\n")
    }

    private static func optionRows(_ flags: [FlagSpec]) -> [Row] {
        var rows: [Row] = []
        var seenGroups: Set<String> = []
        for flag in flags where !flag.hidden {
            if let group = flag.group {
                guard seenGroups.insert(group).inserted else { continue }
                let members = flags.filter { $0.group == group && !$0.hidden }
                rows.append(Row(label: members.map(\.name).joined(separator: "|"), summary: flag.summary))
                continue
            }
            var label = flag.names.joined(separator: ", ")
            switch flag.arity {
            case .none: break
            case .value: label += " \(flag.placeholder)"
            case .optionalValue: label += " [\(flag.placeholder)]"
            }
            rows.append(Row(label: label, summary: flag.summary))
        }
        return rows
    }

    // MARK: - Usage

    /// `usage: kinhin …` lines for a spec, wrapped to `columns`.
    static func usageLines(for spec: CommandSpec, path: [String]) -> [String] {
        let command = path.joined(separator: " ")
        var forms: [String] = []
        if !spec.usage.isEmpty {
            forms = spec.usage.map { "kinhin " + $0 }
        } else {
            let hasSubs = !spec.visibleSubcommands.isEmpty
            if !hasSubs || (!spec.requiresSubcommand && spec.defaultSubcommand == nil) {
                forms.append(
                    (["kinhin", command] + (spec.positionals.isEmpty ? [] : [spec.positionals]) + flagForms(spec.flags))
                        .joined(separator: " "))
            }
            if hasSubs {
                let hasFlags = spec.visibleSubcommands.contains { !$0.flags.filter { !$0.hidden }.isEmpty }
                forms.append("kinhin \(command) <command>" + (hasFlags ? " [options]" : ""))
            }
        }
        var lines: [String] = []
        for (index, form) in forms.enumerated() {
            let prefix = index == 0 ? "usage: " : "       "
            let wrapped = wrap(form, width: columns - 7, indent: "    ")
            for (offset, line) in wrapped.enumerated() {
                lines.append((offset == 0 ? prefix : "       ") + line)
            }
        }
        return lines
    }

    private static func flagForms(_ flags: [FlagSpec]) -> [String] {
        var seenGroups: Set<String> = []
        var forms: [String] = []
        for flag in flags where !flag.hidden {
            if let group = flag.group {
                if seenGroups.insert(group).inserted { forms.append("[--\(group.uppercased())]") }
            } else {
                forms.append("[\(flag.usageForm)]")
            }
        }
        return forms
    }

    // MARK: - Layout

    /// `    label    text`, with the text wrapped beside the label column. A
    /// label wider than the column puts its text on the next line instead.
    private static func table(label: String, text: String, labelWidth: Int) -> [String] {
        let indent = 4
        let gap = 2
        let textColumn = indent + labelWidth + gap
        let textWidth = columns - textColumn
        let prefix = String(repeating: " ", count: indent) + label
        guard !text.isEmpty else { return [prefix] }
        let continuation = String(repeating: " ", count: textColumn)
        if label.count > labelWidth {
            return [prefix] + wrap(text, width: textWidth, indent: "").map { continuation + $0 }
        }
        let wrapped = wrap(text, width: textWidth, indent: "")
        var lines: [String] = []
        for (offset, line) in wrapped.enumerated() {
            if offset == 0 {
                lines.append(prefix + String(repeating: " ", count: labelWidth - label.count + gap) + line)
            } else {
                lines.append(continuation + line)
            }
        }
        return lines
    }

    /// Greedy word wrap to `width` columns; every line begins with `indent`
    /// (which counts toward the width only for the lines after the first).
    static func wrap(_ text: String, width: Int, indent: String) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            let limit = lines.isEmpty ? width : width - indent.count
            if candidate.count > limit, !current.isEmpty {
                lines.append(current)
                current = String(word)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.enumerated().map { $0.offset == 0 ? $0.element : indent + $0.element }
    }
}
