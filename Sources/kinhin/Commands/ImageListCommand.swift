import Foundation
import KinhinKit

/// `kinhin image list` — every image installed on this Mac for the runtimes
/// kinhin bakes for (tart, apple container, Docker), with what each one is,
/// how big it is, and who is using it. Report only; deleting is
/// `kinhin image delete`. Nothing here mutates state, so the command works
/// even when the fleet is running.
enum ImageListCommand {
    /// The `--json` document: every entry, plus the runtimes whose images
    /// could not be listed and why, and each runtime's total disk usage —
    /// the bloat-at-a-glance number, keyed by runtime (a runtime whose
    /// sizes could not be read has no key). Key-sorted and pretty like
    /// every other machine-readable CLI output.
    struct Report: Codable, Equatable {
        var images: [ImageInventory.Entry]
        var unavailable: [String: String]
        var totalGB: [String: Int]
    }

    static func report(for inventory: ImageInventory) -> Report {
        var unavailable: [String: String] = [:]
        var totalGB: [String: Int] = [:]
        for section in inventory.sections {
            if let reason = section.unavailable { unavailable[section.runtime.rawValue] = reason }
            if let total = section.totalGB { totalGB[section.runtime.rawValue] = total }
        }
        return Report(images: inventory.entries, unavailable: unavailable, totalGB: totalGB)
    }

    /// What the flags asked for: the machine-readable form, and (via
    /// `--runtime`, repeatable) the runtimes to list. Parsed before anything
    /// is probed, so a bad flag fails without touching a runtime.
    struct Query: Equatable {
        var json = false
        var only: Set<ImageInventory.Runtime>?

        static func parse(_ args: [String]) throws -> Query {
            var query = Query()
            var index = 0
            while index < args.count {
                let arg = args[index]
                switch arg {
                case "--json":
                    query.json = true
                case "--runtime":
                    guard index + 1 < args.count else {
                        throw CLIError(
                            "--runtime needs a value: tart, container or docker", exit: .usage)
                    }
                    let raw = args[index + 1]
                    guard let runtime = ImageInventory.Runtime(rawValue: raw) else {
                        throw CLIError(
                            "--runtime must be tart, container or docker, got '\(raw)'", exit: .usage)
                    }
                    query.only = (query.only ?? []).union([runtime])
                    index += 1
                default:
                    throw CLIError(
                        "image list takes no image names (got '\(arg)'); flags: --json,"
                            + " --runtime <tart|container|docker>", exit: .usage)
                }
                index += 1
            }
            return query
        }
    }

    static func run(_ args: [String]) async throws {
        let query = try Query.parse(args)
        let inventory = await ImageInventory.probe(config: loadConfigLeniently(), only: query.only)
        if query.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(report(for: inventory)), as: UTF8.self))
            return
        }
        for line in lines(for: inventory) { print(line) }
    }

    // MARK: - Prose

    /// The listing: one section per runtime opening with a count and total
    /// disk usage, one aligned row per image, and the delete hint at the
    /// end. Separate from `run` so tests assert on it.
    static func lines(for inventory: ImageInventory) -> [String] {
        var lines: [String] = []
        for (index, section) in inventory.sections.enumerated() {
            if index > 0 { lines.append("") }
            lines.append(title(for: section.runtime))
            if let reason = section.unavailable {
                lines.append("  not listed — \(reason)")
            } else if section.entries.isEmpty {
                lines.append("  no images installed")
            } else if section.presentCount > 0 {
                lines.append(summary(for: section))
            }
            let width = section.entries.map { $0.name.count }.max() ?? 0
            lines += section.entries.map { row($0, nameWidth: width) }
        }
        if inventory.entries.contains(where: \.present) {
            lines.append("")
            lines.append("delete one with: kinhin image delete <name>")
        }
        return lines
    }

    private static func title(for runtime: ImageInventory.Runtime) -> String {
        switch runtime {
        case .tart: return "tart images (macOS/Linux VM images):"
        case .container: return "apple container images:"
        case .docker: return "docker images:"
        }
    }

    /// The section's headline: how many images are on disk and how much
    /// space they take together — image bloat at a glance. The total is
    /// omitted when the runtime reported no sizes (a per-row "—" already
    /// says why).
    private static func summary(for section: ImageInventory.Section) -> String {
        var line = "  \(section.presentCount) image(s)"
        if let total = section.totalGB {
            line += ", \(total > 0 ? "\(total) GB" : "<1 GB") total"
        }
        return line
    }

    private static func row(_ entry: ImageInventory.Entry, nameWidth: Int) -> String {
        let name = entry.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
        let role = entry.role.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)
        let presence = presence(entry)
        let detail = details(entry)
        // Only pad the status column when a detail follows it — a padded
        // empty column would leave trailing spaces on the line.
        guard !detail.isEmpty else { return "  \(name)  \(role)  \(presence)" }
        let status = presence.padding(toLength: 9, withPad: " ", startingAt: 0)
        return "  \(name)  \(role)  \(status)  \(detail)"
    }
    /// Size (present) vs why there is no size (not built / stale record).
    /// A present image sized below one whole GB reads "<1 GB": "0 GB"
    /// looks like a broken measurement, not a small image.
    private static func presence(_ entry: ImageInventory.Entry) -> String {
        if entry.present {
            guard let size = entry.sizeGB else { return "—" }
            return size > 0 ? "\(size) GB" : "<1 GB"
        }
        return entry.stale ? "stale" : "not built"
    }

    private static func details(_ entry: ImageInventory.Entry) -> String {
        if !entry.present {
            return entry.stale
                ? "no image on disk — `kinhin image delete \(entry.name)` clears this record"
                : "not built — run: \(prepareCommand(for: entry))"
        }
        var parts: [String] = []
        if let summary = entry.summary, !summary.isEmpty { parts.append(summary) }
        if let used = entry.lastUsedAt {
            parts.append("last used \(used.formatted(date: .abbreviated, time: .shortened))")
        }
        if !entry.usedBy.isEmpty {
            let shown = entry.usedBy.prefix(3).joined(separator: ", ")
            let more = entry.usedBy.count > 3 ? ", …" : ""
            parts.append("in use by \(entry.usedBy.count) runner(s): \(shown)\(more)")
        }
        return parts.joined(separator: " · ")
    }

    /// The command that rebuilds an image that is configured but not built.
    private static func prepareCommand(for entry: ImageInventory.Entry) -> String {
        switch entry.runtime {
        case .tart:
            return entry.role == .named
                ? "kinhin image prepare --image \(entry.name)"
                : "kinhin image prepare"
        case .container:
            return "kinhin image prepare --container"
        case .docker:
            return "kinhin image prepare --docker"
        }
    }
}
