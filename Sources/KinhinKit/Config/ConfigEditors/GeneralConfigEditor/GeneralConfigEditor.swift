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
    // MARK: - Writing

    /// Apply one field edit to the file on disk. Field keys are stable API
    /// for the UI; unknown keys are a programming error (unsupported).
    @discardableResult
    public static func apply(_ field: Field, to url: URL = Paths.config) throws -> String {
        try ConfigFileEdit.apply(to: url) { try replace(field: field, in: $0) }
    }

    /// The editable fields, keyed for the UI.
    public enum Field: Equatable, Sendable {
        case labels([String])
        case minRunners(Int)
        case warmPool(Int)
        case maxRunners(Int)
        case runnersPerVM(Int)
        case pollInterval(Int)
        case autoResume(Bool)
        case vmCPU(Int)
        case vmMemoryGB(Int)
        case vmEphemeral(Bool)
        case image(String)
        /// Top-level `base_image:`; nil removes the key.
        case baseImage(String?)
        case reserveCPU(Int)
        case reserveMemoryGB(Int)
        /// `reserve.disk_gb`: free disk kept back for the host.
        case reserveDiskGB(Int)
        /// `warm_max_age_minutes`: how long a warm VM may sit unused before it is replaced.
        case warmMaxAgeMinutes(Int)
        /// Top-level `image_min_idle`: idle runners kept on the default Tart image.
        case imageMinIdle(Int)
        /// `container.min_idle`, edited in place so the section's comments survive. Needs a `container:` section.
        case containerMinIdle(Int)
        /// `docker.min_idle`, edited in place. Needs a `docker:` section.
        case dockerMinIdle(Int)
        /// `docker.max_slots`, edited in place. Needs a `docker:` section.
        case dockerMaxSlots(Int)
        case container(Snapshot.Container?)
        case docker(Snapshot.Docker?)
    }

    // MARK: - Key model

    /// A scalar key at the top level or inside `vm:` / `reserve:`.
    private struct KeyPath {
        var section: String?  // nil = top level
        var key: String

        static func top(_ key: String) -> KeyPath { KeyPath(section: nil, key: key) }
        static func under(_ section: String, _ key: String) -> KeyPath { KeyPath(section: section, key: key) }
    }

    private static func keyPath(for field: Field) -> KeyPath {
        switch field {
        case .labels: return .top("labels")
        case .minRunners: return .top("min_runners")
        case .warmPool: return .top("warm_pool")
        case .maxRunners: return .top("max_runners")
        case .runnersPerVM: return .top("runners_per_vm")
        case .pollInterval: return .top("poll_interval")
        case .autoResume: return .top("auto_resume")
        case .vmCPU: return .under("vm", "cpu")
        case .vmMemoryGB: return .under("vm", "memory_gb")
        case .vmEphemeral: return .under("vm", "ephemeral")
        case .image: return .top("image")
        case .baseImage: return .top("base_image")
        case .reserveCPU: return .under("reserve", "cpu")
        case .reserveMemoryGB: return .under("reserve", "memory_gb")
        case .reserveDiskGB: return .under("reserve", "disk_gb")
        case .warmMaxAgeMinutes: return .top("warm_max_age_minutes")
        case .imageMinIdle: return .top("image_min_idle")
        case .containerMinIdle: return .under("container", "min_idle")
        case .dockerMinIdle: return .under("docker", "min_idle")
        case .dockerMaxSlots: return .under("docker", "max_slots")
        case .container, .docker: return .top("unused")  // handled separately
        }
    }

    private static func valueText(for field: Field) -> String {
        func intText(_ v: Int) -> String { String(v) }
        func boolText(_ v: Bool) -> String { v ? "true" : "false" }
        let quoted = YAMLText.quoted
        switch field {
        case .labels(let list):
            return "[" + list.map { quoted($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: ", ") + "]"
        case .minRunners(let n), .warmPool(let n), .maxRunners(let n), .runnersPerVM(let n), .pollInterval(let n),
            .vmCPU(let n), .vmMemoryGB(let n), .reserveCPU(let n), .reserveMemoryGB(let n), .reserveDiskGB(let n),
            .warmMaxAgeMinutes(let n), .imageMinIdle(let n), .containerMinIdle(let n), .dockerMinIdle(let n),
            .dockerMaxSlots(let n):
            return intText(n)
        case .vmEphemeral(let b): return boolText(b)
        case .autoResume(let b): return boolText(b)
        case .image(let s): return quoted(s)
        case .baseImage(let s): return quoted(s ?? "")  // nil is handled in replace
        case .container, .docker: return ""  // handled separately
        }
    }

    /// Rewrite the file text with the field's new value, preserving
    /// comments everywhere else. Creates the parent section (`vm:` /
    /// `reserve:`) when missing.
    static func replace(field: Field, in yaml: String) throws -> String {
        switch field {
        case .container(let c):
            return try replaceSectionToggle("container", present: c != nil, in: yaml) { c.map(sectionText) }
        case .docker(let d):
            return try replaceSectionToggle("docker", present: d != nil, in: yaml) { d.map(sectionText) }
        case .baseImage(nil):
            // Clearing the tart base image removes the key entirely (the
            // default must never be pinned into the file).
            // Column-0 only: `container:` / `docker:` carry their own
            // indented `base_image:`, which must survive.
            var lines = yaml.components(separatedBy: "\n")
            if let idx = lines.firstIndex(where: { $0.hasPrefix("base_image:") }) {
                lines.remove(at: idx)
            }
            return lines.joined(separator: "\n")
        default: break
        }

        let root: Node?
        do {
            root = try Yams.compose(yaml: yaml)
        } catch {
            throw ConfigEditError.yamlParse(error.localizedDescription)
        }
        guard let root, root.mapping != nil else {
            throw ConfigEditError.yamlParse("top level must be a mapping")
        }
        let path = keyPath(for: field)
        // A key edited inside `container:` / `docker:` never creates the section: a bare one would not be valid.
        if let section = path.section, ["container", "docker"].contains(section),
            !yaml.components(separatedBy: "\n").contains(where: {
                YAMLText.isTopLevelKey($0) && $0.hasPrefix("\(section):")
            })
        {
            throw ConfigEditError.unsupported("\(section) isn't enabled in config.yaml")
        }
        let value = valueText(for: field)
        var lines = yaml.components(separatedBy: "\n")

        let isTopKey = YAMLText.isTopLevelKey
        func indent(of line: String) -> Int { YAMLText.indent(of: line) }

        // Find (or create) the section line, then the key line inside it.
        var sectionIdx: Int? = nil
        if let section = path.section {
            sectionIdx = lines.firstIndex(where: {
                isTopKey($0) && $0.trimmingCharacters(in: .whitespaces) == "\(section):"
            })
            if sectionIdx == nil {
                // Append the section header before writing the key.
                YAMLText.trimTrailingBlankLines(&lines)
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
            YAMLText.trimTrailingBlankLines(&lines)
            lines.append(newLine)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Base image

    /// Sets (or, with nil, clears) what a runtime's prepare starts from: the
    /// tart `base_image:` key for `.tart`, the section's `base_image:` for
    /// Apple container or Docker. Everything else in the file is left alone;
    /// nothing is written when the result doesn't parse.
    @discardableResult
    public static func setBaseImage(_ image: String?, for runtime: RuntimeID, at url: URL) throws -> String {
        guard let snapshot = try ConfigStore.snapshot(at: url) else { throw ConfigEditError.notFound(url.path) }
        switch runtime {
        case .tart:
            if let image {
                if let problem = TartBaseImage.problem(with: image) {
                    throw ConfigEditError.rejected("base image \(problem)")
                }
            }
            return try apply(.baseImage(image), to: url)
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
            throw ConfigEditError.unsupported("only tart, Apple container and Docker bake from a base image")
        }
    }

    // MARK: - Docker platform

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
