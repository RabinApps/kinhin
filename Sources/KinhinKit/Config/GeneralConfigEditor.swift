import Foundation
import Yams

/// Reads and writes the *general* config keys — the fleet's identity and
/// shape (`repo`, `labels`, runner counts, poll interval, VM resources,
/// headroom, image) and the optional forge/runtime sections (`gitea`,
/// `container`, `docker`) — by targeted text surgery, exactly like
/// `RuntimesConfigEditor` and `LabelsConfigEditor`:
///
/// - everything outside the edited key keeps its comments and formatting
/// - the whole updated file must still parse through `ConfigLoader.parse`
///   (the engine's own validation) or nothing is written
///
/// The app's Config tab and onboarding wizard edit through this — never by
/// re-serializing the whole document (Yams would drop the user's comments).
public enum GeneralConfigEditor {
    // MARK: Reading

    /// The typed subset the UI edits, decoded from the raw YAML.
    public struct Snapshot: Equatable, Sendable {
        public var repo: String
        public var labels: [String]
        public var minRunners: Int
        public var maxRunners: Int
        public var runnersPerVM: Int
        public var pollInterval: Int
        public var vmCPU: Int
        public var vmMemoryGB: Int
        public var vmEphemeral: Bool
        public var image: String
        public var reserveCPU: Int
        public var reserveMemoryGB: Int
        public var gitea: Gitea?
        public var container: Container?
        public var docker: Docker?

        public struct Gitea: Equatable, Sendable {
            public var instance: String
            public var scope: String
            public init(instance: String, scope: String) {
                self.instance = instance
                self.scope = scope
            }
        }

        public struct Container: Equatable, Sendable {
            public var image: String
            public var cpus: Int
            public var memoryGB: Int
            public init(image: String, cpus: Int, memoryGB: Int) {
                self.image = image
                self.cpus = cpus
                self.memoryGB = memoryGB
            }
        }

        public struct Docker: Equatable, Sendable {
            public var image: String
            public var cpus: Int
            public var memoryGB: Int
            public var maxSlots: Int
            public init(image: String, cpus: Int, memoryGB: Int, maxSlots: Int) {
                self.image = image
                self.cpus = cpus
                self.memoryGB = memoryGB
                self.maxSlots = maxSlots
            }
        }
    }

    /// Decode the editable subset from config text (defaults filled from
    /// `KinhinConfig.default` where the key is absent). Throws when the text
    /// is not valid YAML at all — callers surface that instead of editing
    /// against a phantom snapshot.
    public static func snapshot(from yaml: String) throws -> Snapshot {
        guard let root = try? Yams.compose(yaml: yaml), root.mapping != nil else {
            throw ConfigEditError.yamlParse("top level must be a mapping")
        }
        let partial = try? YAMLDecoder().decode(PartialConfig.self, from: yaml)
        let d = KinhinConfig.default
        let vm = partial?.vm
        let reserve = partial?.reserve
        return Snapshot(
            repo: partial?.repo ?? "",
            labels: partial?.labels ?? d.labels,
            minRunners: partial?.minRunners ?? d.minRunners,
            maxRunners: partial?.maxRunners ?? d.maxRunners,
            runnersPerVM: partial?.runnersPerVM ?? d.runnersPerVM,
            pollInterval: partial?.pollInterval ?? d.pollInterval,
            vmCPU: vm?.cpu ?? d.vm.cpuCount,
            vmMemoryGB: vm?.memoryGB ?? d.vm.memoryGB,
            vmEphemeral: vm?.ephemeral ?? d.vm.ephemeral,
            image: partial?.image ?? d.image,
            reserveCPU: reserve?.cpu ?? d.reserve.cpu,
            reserveMemoryGB: reserve?.memoryGB ?? d.reserve.memoryGB,
            gitea: partial?.gitea.map { .init(instance: $0.instance ?? "", scope: $0.scope ?? "") },
            container: partial?.container.map {
                .init(image: $0.image ?? "kinhin-ci-linux", cpus: $0.cpus ?? 4, memoryGB: $0.memoryGB ?? 8)
            },
            docker: partial?.docker.map {
                .init(
                    image: $0.image ?? "kinhin-ci-linux", cpus: $0.cpus ?? 2, memoryGB: $0.memoryGB ?? 4,
                    maxSlots: $0.maxSlots ?? 8)
            }
        )
    }

    // MARK: Writing

    /// Apply one field edit to the file on disk. Field keys are stable API
    /// for the UI; unknown keys are a programming error (unsupported).
    @discardableResult
    public static func apply(_ field: Field, to url: URL = Paths.config) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigEditError.notFound(url.path)
        }
        let original = try String(contentsOf: url, encoding: .utf8)
        let updated = try replace(field: field, in: original)
        do {
            _ = try ConfigLoader.parse(updated)
        } catch {
            throw ConfigEditError.validation(error.localizedDescription)
        }
        try updated.write(toFile: url.path, atomically: true, encoding: .utf8)
        return updated
    }

    /// The editable fields, keyed for the UI.
    public enum Field: Equatable, Sendable {
        case repo(String)
        case labels([String])
        case minRunners(Int)
        case maxRunners(Int)
        case runnersPerVM(Int)
        case pollInterval(Int)
        case vmCPU(Int)
        case vmMemoryGB(Int)
        case vmEphemeral(Bool)
        case image(String)
        case reserveCPU(Int)
        case reserveMemoryGB(Int)
        /// Toggle the whole `gitea:` section: nil removes it.
        case gitea(Snapshot.Gitea?)
        case container(Snapshot.Container?)
        case docker(Snapshot.Docker?)
    }

    // MARK: Key model

    /// A scalar key at the top level or inside `vm:` / `reserve:`.
    private struct KeyPath {
        var section: String?  // nil = top level
        var key: String

        static func top(_ key: String) -> KeyPath { KeyPath(section: nil, key: key) }
        static func under(_ section: String, _ key: String) -> KeyPath { KeyPath(section: section, key: key) }
    }

    private static func keyPath(for field: Field) -> KeyPath {
        switch field {
        case .repo: return .top("repo")
        case .labels: return .top("labels")
        case .minRunners: return .top("min_runners")
        case .maxRunners: return .top("max_runners")
        case .runnersPerVM: return .top("runners_per_vm")
        case .pollInterval: return .top("poll_interval")
        case .vmCPU: return .under("vm", "cpu")
        case .vmMemoryGB: return .under("vm", "memory_gb")
        case .vmEphemeral: return .under("vm", "ephemeral")
        case .image: return .top("image")
        case .reserveCPU: return .under("reserve", "cpu")
        case .reserveMemoryGB: return .under("reserve", "memory_gb")
        case .gitea, .container, .docker: return .top("unused")  // handled separately
        }
    }

    private static func valueText(for field: Field) -> String {
        func intText(_ v: Int) -> String { String(v) }
        func boolText(_ v: Bool) -> String { v ? "true" : "false" }
        func quoted(_ s: String) -> String {
            let escaped =
                s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        switch field {
        case .repo(let s): return quoted(s)
        case .labels(let list):
            return "[" + list.map { quoted($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: ", ") + "]"
        case .minRunners(let v), .maxRunners(let v), .runnersPerVM(let v),
            .pollInterval(let v), .vmCPU(let v), .vmMemoryGB(let v),
            .reserveCPU(let v), .reserveMemoryGB(let v):
            if case .minRunners(let n) = field { return intText(n) }
            if case .maxRunners(let n) = field { return intText(n) }
            if case .runnersPerVM(let n) = field { return intText(n) }
            if case .pollInterval(let n) = field { return intText(n) }
            if case .vmCPU(let n) = field { return intText(n) }
            if case .vmMemoryGB(let n) = field { return intText(n) }
            if case .reserveCPU(let n) = field { return intText(n) }
            if case .reserveMemoryGB(let n) = field { return intText(n) }
            return "0"
        case .vmEphemeral(let b): return boolText(b)
        case .image(let s): return quoted(s)
        case .gitea, .container, .docker: return ""  // handled separately
        }
    }

    /// Rewrite the file text with the field's new value, preserving
    /// comments everywhere else. Creates the parent section (`vm:` /
    /// `reserve:`) when missing.
    static func replace(field: Field, in yaml: String) throws -> String {
        switch field {
        case .gitea(let g): return try replaceSectionToggle("gitea", present: g != nil, in: yaml) { g.map(sectionText) }
        case .container(let c):
            return try replaceSectionToggle("container", present: c != nil, in: yaml) { c.map(sectionText) }
        case .docker(let d):
            return try replaceSectionToggle("docker", present: d != nil, in: yaml) { d.map(sectionText) }
        default: break
        }

        guard let root = try? Yams.compose(yaml: yaml), root.mapping != nil else {
            throw ConfigEditError.yamlParse("top level must be a mapping")
        }
        let path = keyPath(for: field)
        let value = valueText(for: field)
        var lines = yaml.components(separatedBy: "\n")

        func isTopKey(_ line: String) -> Bool {
            guard let first = line.first, first != "#", first != "-" else { return false }
            return line.hasPrefix(line.trimmingCharacters(in: .whitespaces)) && line.contains(":")
        }
        func indent(of line: String) -> Int { line.count - line.drop(while: { $0 == " " }).count }

        // Find (or create) the section line, then the key line inside it.
        var sectionIdx: Int? = nil
        if let section = path.section {
            sectionIdx = lines.firstIndex(where: {
                isTopKey($0) && $0.trimmingCharacters(in: .whitespaces) == "\(section):"
            })
            if sectionIdx == nil {
                // Append the section header before writing the key.
                while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
                lines.append("\(section):")
                sectionIdx = lines.count - 1
            }
        }

        let baseIndent = path.section != nil ? 2 : 0
        let keyPrefix = String(repeating: " ", count: baseIndent) + "\(path.key):"

        var searchStart = sectionIdx.map { $0 + 1 } ?? 0
        var keyIdx: Int? = nil
        for index in searchStart..<lines.count {
            let line = lines[index]
            if indent(of: line) == baseIndent, line.hasPrefix(keyPrefix) {
                keyIdx = index
                break
            }
            // Nested keys live inside their section's block: the next
            // top-level mapping line ends the search. Top-level keys are
            // themselves top-level lines, so the scan crosses every other
            // key and covers the whole document (YAML forbids duplicates,
            // making the first match unambiguous).
            if path.section != nil, isTopKey(line) {
                break
            }
        }

        let newLine = "\(keyPrefix) \(value)"
        if let idx = keyIdx {
            // Preserve a trailing comment on the edited line.
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            if let commentRange = trimmed.range(of: " #"), trimmed.hasSuffix(":") == false {
                _ = commentRange  // comment handling: append to the new line
                let comment = trimmed[commentRange.lowerBound...]
                lines[idx] = newLine + " " + comment
            } else {
                lines[idx] = newLine
            }
        } else if let section = sectionIdx {
            lines.insert(newLine, at: section + 1)
        } else {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines.append(newLine)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Section toggles (gitea / container / docker)

    /// Remove or (re)write a whole top-level section block. `newText` renders
    /// the section when present.
    static func replaceSectionToggle(_ name: String, present: Bool, in yaml: String, newText: () -> String?) throws
        -> String
    {
        guard let root = try? Yams.compose(yaml: yaml), root.mapping != nil else {
            throw ConfigEditError.yamlParse("top level must be a mapping")
        }
        var lines = yaml.components(separatedBy: "\n")

        func isTopKey(_ line: String) -> Bool {
            guard let first = line.first, first != "#", first != "-" else { return false }
            return line.hasPrefix(line.trimmingCharacters(in: .whitespaces)) && line.contains(":")
        }

        if let start = lines.firstIndex(where: { isTopKey($0) && $0.trimmingCharacters(in: .whitespaces) == "\(name):" }
        ) {
            var end = lines.count
            for index in (start + 1)..<lines.count where isTopKey(lines[index]) {
                end = index
                break
            }
            if present {
                let block = (newText() ?? "").components(separatedBy: "\n")
                lines.replaceSubrange(start..<end, with: block)
            } else {
                lines.replaceSubrange(start..<end, with: [])
            }
            return lines.joined(separator: "\n")
        }
        guard present, let block = newText() else { return lines.joined(separator: "\n") }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        lines.append(contentsOf: block.components(separatedBy: "\n"))
        return lines.joined(separator: "\n")
    }

    private static func sectionText(_ g: Snapshot.Gitea) -> String {
        """
        gitea:
          instance: \(quote(g.instance))
          scope: \(quote(g.scope))
        """
    }

    private static func sectionText(_ c: Snapshot.Container) -> String {
        """
        container:
          image: \(quote(c.image))
          cpus: \(c.cpus)
          memory_gb: \(c.memoryGB)
        """
    }

    private static func sectionText(_ d: Snapshot.Docker) -> String {
        """
        docker:
          image: \(quote(d.image))
          cpus: \(d.cpus)
          memory_gb: \(d.memoryGB)
          max_slots: \(d.maxSlots)
        """
    }

    private static func quote(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
