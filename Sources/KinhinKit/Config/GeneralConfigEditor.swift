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

        /// The configured base image for a Linux runtime (nil = default).
        /// The configured Docker platform (arm64 when absent or unrecognized).
        public var dockerPlatform: LinuxPlatform {
            docker?.platform.flatMap { LinuxPlatform(configValue: $0) } ?? .arm64
        }

        public func baseImage(for runtime: RuntimeID) -> String? {
            switch runtime {
            case .appleContainer: return container?.baseImage
            case .docker: return docker?.baseImage
            default: return nil
            }
        }

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
            /// See `KinhinConfig.ContainerConfig.baseImage` / `.labels`; carried so a
            /// section rewrite doesn't drop them.
            public var baseImage: String?
            public var labels: [String]?
            public init(
                image: String, cpus: Int, memoryGB: Int, baseImage: String? = nil, labels: [String]? = nil
            ) {
                self.image = image
                self.cpus = cpus
                self.memoryGB = memoryGB
                self.baseImage = baseImage
                self.labels = labels
            }
        }

        public struct Docker: Equatable, Sendable {
            public var image: String
            public var cpus: Int
            public var memoryGB: Int
            public var maxSlots: Int
            public var baseImage: String?
            /// Raw `docker.platform:` value, carried so a rewrite of the section keeps it.
            public var platform: String?
            public init(
                image: String, cpus: Int, memoryGB: Int, maxSlots: Int, baseImage: String? = nil,
                platform: String? = nil
            ) {
                self.image = image
                self.cpus = cpus
                self.memoryGB = memoryGB
                self.maxSlots = maxSlots
                self.baseImage = baseImage
                self.platform = platform
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
                .init(
                    image: $0.image ?? "kinhin-ci-linux", cpus: $0.cpus ?? 4, memoryGB: $0.memoryGB ?? 8,
                    baseImage: $0.baseImage, labels: $0.labels)
            },
            docker: partial?.docker.map {
                .init(
                    image: $0.image ?? "kinhin-ci-linux", cpus: $0.cpus ?? 2, memoryGB: $0.memoryGB ?? 4,
                    maxSlots: $0.maxSlots ?? 8, baseImage: $0.baseImage, platform: $0.platform)
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

    // MARK: Base image

    /// Sets (or, with nil, clears) `base_image:` for the Apple container or
    /// Docker section, leaving everything else in the file alone. Validated
    /// like any other edit: nothing is written if the result doesn't parse.
    @discardableResult
    public static func setBaseImage(_ image: String?, for runtime: RuntimeID, at url: URL) throws -> String {
        guard let snapshot = try ConfigStore.snapshot(at: url) else { throw ConfigEditError.notFound(url.path) }
        switch runtime {
        case .appleContainer:
            guard var container = snapshot.container else {
                throw ConfigEditError.unsupported("Apple container isn't enabled in config.yaml")
            }
            container.baseImage = image
            return try apply(.container(container), to: url)
        case .docker:
            guard var docker = snapshot.docker else {
                throw ConfigEditError.unsupported("Docker isn't enabled in config.yaml")
            }
            docker.baseImage = image
            return try apply(.docker(docker), to: url)
        default:
            throw ConfigEditError.unsupported("only Apple container and Docker are baked from a base image")
        }
    }

    // MARK: Docker platform

    /// Sets `docker.platform:` (arm64 is the default and is written out only
    /// when explicitly chosen away from it, so existing files stay tidy).
    /// Leaves everything else in the file alone; nothing is written if the
    /// result doesn't parse.
    @discardableResult
    public static func setDockerPlatform(_ platform: LinuxPlatform, at url: URL) throws -> String {
        guard let snapshot = try ConfigStore.snapshot(at: url) else { throw ConfigEditError.notFound(url.path) }
        guard var docker = snapshot.docker else {
            throw ConfigEditError.unsupported("Docker isn't enabled in config.yaml")
        }
        docker.platform = platform == .arm64 ? nil : platform.rawValue
        return try apply(.docker(docker), to: url)
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
        var lines = ["container:", "  image: \(quote(c.image))"]
        if let base = c.baseImage, !base.isEmpty { lines.append("  base_image: \(quote(base))") }
        lines += ["  cpus: \(c.cpus)", "  memory_gb: \(c.memoryGB)"]
        if let labels = c.labels { lines.append("  labels: [\(labels.map(quote).joined(separator: ", "))]") }
        return lines.joined(separator: "\n")
    }

    private static func sectionText(_ d: Snapshot.Docker) -> String {
        var lines = ["docker:", "  image: \(quote(d.image))"]
        if let base = d.baseImage, !base.isEmpty { lines.append("  base_image: \(quote(base))") }
        lines += ["  cpus: \(d.cpus)", "  memory_gb: \(d.memoryGB)", "  max_slots: \(d.maxSlots)"]
        if let platform = d.platform, !platform.isEmpty { lines.append("  platform: \(quote(platform))") }
        return lines.joined(separator: "\n")
    }

    private static func quote(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
