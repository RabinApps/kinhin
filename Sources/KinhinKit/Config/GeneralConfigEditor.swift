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
        case autoResume(Bool)
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
        case .autoResume: return .top("auto_resume")
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
        case .minRunners, .maxRunners, .runnersPerVM,
            .pollInterval, .vmCPU, .vmMemoryGB,
            .reserveCPU, .reserveMemoryGB:
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
        case .autoResume(let b): return boolText(b)
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

        let searchStart = sectionIdx.map { $0 + 1 } ?? 0
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
}
