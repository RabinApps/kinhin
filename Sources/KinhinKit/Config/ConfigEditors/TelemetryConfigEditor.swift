import Foundation
import Yams

/// Edits the `telemetry:` section of the config YAML (the app's Telemetry card) by targeted text surgery, like
/// `LabelsConfigEditor`: only the edited key's line changes, so comments and every other key (`endpoint`, `signals`,
/// `resource_attributes`, …) survive, and the whole updated file must still pass `ConfigLoader.parse` before anything is
/// written. Only the two keys the app offers are editable here; the rest stay a matter for the YAML file.
public enum TelemetryConfigEditor {
    /// What the app can change.
    public enum Field: Equatable, Sendable {
        /// `telemetry.enabled`.
        case enabled(Bool)
        /// `telemetry.prometheus_listen` (`host:port` or a bare port); nil removes the key (no listener).
        case prometheusListen(String?)
    }

    /// The editable keys as they stand in the file.
    public struct Snapshot: Equatable, Sendable {
        public var enabled: Bool
        public var prometheusListen: String?
    }

    /// The current values. Blank text, or no `telemetry:` section, reads as the defaults (off, no listener); text that
    /// does not decode throws instead of reading as default.
    public static func snapshot(in yaml: String) throws -> Snapshot {
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Snapshot(enabled: false, prometheusListen: nil)
        }
        do {
            let partial = try YAMLDecoder().decode(PartialConfig.self, from: yaml)
            return Snapshot(
                enabled: partial.telemetry?.enabled ?? false, prometheusListen: partial.telemetry?.prometheusListen)
        } catch {
            throw ConfigEditError.decoding(error)
        }
    }

    /// Applies one edit to the file on disk and returns the written text. Nothing is written when the result does not
    /// validate (for example a malformed address, or a listener without the `metrics` signal).
    @discardableResult
    public static func apply(_ field: Field, to url: URL = Paths.config) throws -> String {
        if case .prometheusListen(let raw?) = field, raw.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ConfigEditError.validation("telemetry.prometheus_listen must be a port or host:port, or removed")
        }
        return try ConfigFileEdit.apply(to: url) { try replace(field, in: $0) }
    }

    // MARK: - Text surgery

    static func replace(_ field: Field, in yaml: String) throws -> String {
        guard let root = try Yams.compose(yaml: yaml), root.mapping != nil else {
            throw ConfigEditError.yamlParse("top level must be a mapping")
        }
        let key: String
        let value: String?
        switch field {
        case .enabled(let on):
            key = "enabled"
            value = on ? "true" : "false"
        case .prometheusListen(let address):
            key = "prometheus_listen"
            value = address.map { YAMLText.quoted($0.trimmingCharacters(in: .whitespaces)) }
        }

        var lines = yaml.components(separatedBy: "\n")
        guard let header = lines.firstIndex(where: { YAMLText.isTopLevelKey($0) && isTelemetryKey($0) }) else {
            // No section yet means off with no listener, so only turning something on needs one.
            guard let value, field != .enabled(false) else { return yaml }
            YAMLText.trimTrailingBlankLines(&lines)
            lines.append(contentsOf: ["telemetry:", "  \(key): \(value)"])
            return lines.joined(separator: "\n")
        }
        let headerText = lines[header].trimmingCharacters(in: .whitespaces)
        let afterColon = headerText.dropFirst("telemetry:".count).trimmingCharacters(in: .whitespaces)
        guard afterColon.isEmpty || afterColon.hasPrefix("#") else {
            // `telemetry: {enabled: true}` (flow style) or a scalar: no child lines to edit.
            throw ConfigEditError.unsupported(
                "telemetry: must use block style (one key per line) to be edited here; edit config.yaml directly")
        }

        // The section's lines run to the next top-level key; blank and comment lines are part of it.
        var end = lines.count
        for index in (header + 1)..<lines.count where YAMLText.isTopLevelKey(lines[index]) {
            end = index
            break
        }
        // Children share the first indented key's indent (default 2).
        let childIndent =
            lines[(header + 1)..<end]
            .first { isKeyLine($0) && YAMLText.indent(of: $0) > 0 }
            .map { YAMLText.indent(of: $0) } ?? 2
        let prefix = String(repeating: " ", count: childIndent) + "\(key):"

        let existing = ((header + 1)..<end).first {
            YAMLText.indent(of: lines[$0]) == childIndent && isKey(lines[$0], prefix: prefix)
        }
        switch (existing, value) {
        case (let index?, let value?):
            // Keep a trailing comment on the edited line.
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            let comment = trimmed.range(of: " #").map { String(trimmed[$0.lowerBound...]) } ?? ""
            lines[index] = "\(prefix) \(value)\(comment)"
        case (let index?, nil):
            lines.remove(at: index)
        case (nil, let value?):
            lines.insert("\(prefix) \(value)", at: header + 1)
        case (nil, nil):
            return yaml
        }
        return lines.joined(separator: "\n")
    }

    private static func isTelemetryKey(_ line: String) -> Bool {
        guard line.hasPrefix("telemetry:") else { return false }
        let rest = line.dropFirst("telemetry:".count)
        return rest.isEmpty || rest.hasPrefix(" ")
    }

    /// A mapping-key line (not blank, not a comment or list item).
    private static func isKeyLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.hasPrefix("-") && trimmed.contains(":")
    }

    /// `prefix` is `<indent><key>:`; the key must end there (`enabled:` must not match `enabled_x:`).
    private static func isKey(_ line: String, prefix: String) -> Bool {
        guard line.hasPrefix(prefix) else { return false }
        let rest = line.dropFirst(prefix.count)
        return rest.isEmpty || rest.hasPrefix(" ")
    }
}
