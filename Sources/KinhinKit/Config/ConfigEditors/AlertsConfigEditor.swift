import Foundation
import Yams

/// Edits the `alerts:` section of the config YAML (the app's Alerts card) by targeted text surgery, like
/// `TelemetryConfigEditor`: `enabled` is a one-line edit, and a webhook change rewrites only the `webhooks:` list
/// (a legacy single `webhook:` block is folded into it as the webhook named `default`). Every other key and comment
/// in the file survives, and the whole updated file must still pass `ConfigLoader.parse` before anything is written.
/// Comments written inside the `webhooks:` list itself are not kept when the list is rewritten.
public enum AlertsConfigEditor {
    /// What the app can change.
    public enum Field: Equatable, Sendable {
        /// `alerts.enabled`.
        case enabled(Bool)
        /// Adds a webhook, or replaces the one called `replacing` (rename and edit in one step).
        case saveWebhook(KinhinConfig.AlertsConfig.Webhook, replacing: String?)
        /// Removes the webhook called this.
        case removeWebhook(String)
    }

    /// The editable state as it stands in the file.
    public struct Snapshot: Equatable, Sendable {
        public var enabled: Bool
        public var webhooks: [KinhinConfig.AlertsConfig.Webhook]
    }

    /// The current values. Blank text, or no `alerts:` section, reads as off with no webhooks; text that does not
    /// decode, or a webhook that does not validate, throws instead of reading as default.
    public static func snapshot(in yaml: String) throws -> Snapshot {
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Snapshot(enabled: false, webhooks: [])
        }
        do {
            let partial = try YAMLDecoder().decode(PartialConfig.self, from: yaml)
            guard let alerts = partial.alerts else { return Snapshot(enabled: false, webhooks: []) }
            return Snapshot(enabled: alerts.enabled ?? false, webhooks: try webhooks(of: alerts))
        } catch {
            throw ConfigEditError.decoding(error)
        }
    }

    private static func webhooks(of alerts: PartialConfig.PartialAlerts) throws -> [KinhinConfig.AlertsConfig.Webhook] {
        var result: [KinhinConfig.AlertsConfig.Webhook] = []
        if var legacy = alerts.webhook, legacy.url != nil {
            legacy.name = KinhinConfig.AlertsConfig.Webhook.legacyName
            result.append(try ConfigLoader.parseWebhook(legacy, key: "alerts.webhook"))
        }
        for (index, raw) in (alerts.webhooks ?? []).enumerated() {
            result.append(try ConfigLoader.parseWebhook(raw, key: "alerts.webhooks[\(index)]"))
        }
        return result
    }

    /// Applies one edit to the file on disk and returns the written text. Nothing is written when the result does not
    /// validate (a duplicate name, a bad URL, switching alerts on with no webhook).
    @discardableResult
    public static func apply(_ field: Field, to url: URL = Paths.config) throws -> String {
        try ConfigFileEdit.apply(to: url) { try replace(field, in: $0) }
    }

    // MARK: - Text surgery

    static func replace(_ field: Field, in yaml: String) throws -> String {
        guard let root = try Yams.compose(yaml: yaml), root.mapping != nil else {
            throw ConfigEditError.yamlParse("top level must be a mapping")
        }
        var lines = yaml.components(separatedBy: "\n")
        guard let header = lines.firstIndex(where: { YAMLText.isTopLevelKey($0) && isAlertsKey($0) }) else {
            return try addingSection(field, to: yaml, lines: lines)
        }
        let afterColon = lines[header].trimmingCharacters(in: .whitespaces).dropFirst("alerts:".count)
            .trimmingCharacters(in: .whitespaces)
        guard afterColon.isEmpty || afterColon.hasPrefix("#") else {
            throw ConfigEditError.unsupported(
                "alerts: must use block style (one key per line) to be edited here; edit config.yaml directly")
        }
        var end = lines.count
        for index in (header + 1)..<lines.count where YAMLText.isTopLevelKey(lines[index]) {
            end = index
            break
        }
        let childIndent =
            lines[(header + 1)..<end].first { isKeyLine($0) && YAMLText.indent(of: $0) > 0 }
            .map { YAMLText.indent(of: $0) } ?? 2

        switch field {
        case .enabled(let on):
            let prefix = String(repeating: " ", count: childIndent) + "enabled:"
            if let index = ((header + 1)..<end).first(where: {
                YAMLText.indent(of: lines[$0]) == childIndent && isKey(lines[$0], prefix: prefix)
            }) {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                let comment = trimmed.range(of: " #").map { String(trimmed[$0.lowerBound...]) } ?? ""
                lines[index] = "\(prefix) \(on)\(comment)"
            } else {
                lines.insert("\(prefix) \(on)", at: header + 1)
            }
        case .saveWebhook, .removeWebhook:
            var current = try snapshot(in: yaml).webhooks
            switch field {
            case .saveWebhook(let webhook, let replacing):
                if let replacing, let index = current.firstIndex(where: { $0.name == replacing }) {
                    current[index] = webhook
                } else {
                    current.append(webhook)
                }
            case .removeWebhook(let name):
                current.removeAll { $0.name == name }
            case .enabled: break
            }
            // Drop the old blocks (legacy `webhook:` and `webhooks:`), then write the list where the first one was.
            var insertAt: Int?
            for key in ["webhook:", "webhooks:"] {
                let prefix = String(repeating: " ", count: childIndent) + key
                while let start = ((header + 1)..<end).first(where: {
                    YAMLText.indent(of: lines[$0]) == childIndent && isKey(lines[$0], prefix: prefix)
                }) {
                    let rest = lines[start].dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                    guard rest.isEmpty || rest.hasPrefix("#") || rest == "[]" else {
                        throw ConfigEditError.unsupported(
                            "\(key.dropLast()) must use block style to be edited here; edit config.yaml directly")
                    }
                    let blockEnd = blockEnd(after: start, in: lines, upTo: end, indent: childIndent)
                    lines.removeSubrange(start..<blockEnd)
                    end -= blockEnd - start
                    insertAt = min(insertAt ?? start, start)
                }
            }
            if !current.isEmpty {
                let block = render(current, indent: childIndent)
                let at = insertAt ?? contentEnd(header: header, end: end, in: lines)
                lines.insert(contentsOf: block, at: at)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// No `alerts:` section yet: only a change that has something to write adds one.
    private static func addingSection(_ field: Field, to yaml: String, lines: [String]) throws -> String {
        var lines = lines
        var section = ["alerts:"]
        switch field {
        case .enabled(let on):
            guard on else { return yaml }
            section.append("  enabled: true")
        case .saveWebhook(let webhook, _):
            section.append(contentsOf: render([webhook], indent: 2))
        case .removeWebhook:
            return yaml
        }
        YAMLText.trimTrailingBlankLines(&lines)
        lines.append(contentsOf: section)
        return lines.joined(separator: "\n")
    }

    /// The `webhooks:` list as block-style lines under keys at `indent`.
    static func render(_ webhooks: [KinhinConfig.AlertsConfig.Webhook], indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        var out = ["\(pad)webhooks:"]
        for webhook in webhooks {
            var fields = [
                "name: \(YAMLText.quoted(webhook.name))", "url: \(YAMLText.quoted(webhook.url))",
                "format: \(webhook.format.rawValue)",
            ]
            if let keychain = webhook.headersKeychain {
                fields.append("headers_keychain: \(YAMLText.quoted(keychain))")
            }
            if let severity = webhook.minSeverity { fields.append("min_severity: \(severity.rawValue)") }
            if let events = webhook.events {
                fields.append("events: [\(events.sorted().map(\.rawValue).joined(separator: ", "))]")
            }
            if let resolve = webhook.notifyOnResolve { fields.append("notify_on_resolve: \(resolve)") }
            for (index, field) in fields.enumerated() {
                out.append("\(pad)  \(index == 0 ? "- " : "  ")\(field)")
            }
        }
        return out
    }

    /// Where the block whose key line is `start` stops: after its last non-blank, non-comment line, so comments
    /// between it and the next key stay outside.
    private static func blockEnd(after start: Int, in lines: [String], upTo end: Int, indent: Int) -> Int {
        var last = start
        var index = start + 1
        while index < end {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }
            let lineIndent = YAMLText.indent(of: lines[index])
            // A list at the key's own indent (`webhooks:` then `- name:`) still belongs to the key.
            guard lineIndent > indent || (lineIndent == indent && trimmed.hasPrefix("-")) else { break }
            last = index
            index += 1
        }
        return last + 1
    }

    /// The index after the section's last content line, so an appended key lands before trailing blank lines.
    private static func contentEnd(header: Int, end: Int, in lines: [String]) -> Int {
        var at = end
        while at > header + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
        return at
    }

    private static func isAlertsKey(_ line: String) -> Bool {
        guard line.hasPrefix("alerts:") else { return false }
        let rest = line.dropFirst("alerts:".count)
        return rest.isEmpty || rest.hasPrefix(" ")
    }

    private static func isKeyLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.hasPrefix("-") && trimmed.contains(":")
    }

    private static func isKey(_ line: String, prefix: String) -> Bool {
        guard line.hasPrefix(prefix) else { return false }
        let rest = line.dropFirst(prefix.count)
        return rest.isEmpty || rest.hasPrefix(" ")
    }
}
