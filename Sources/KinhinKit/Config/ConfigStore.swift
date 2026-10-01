import Foundation

/// Reads `config.yaml` for the UI. Unlike `(try? String(contentsOf:)) ?? ""`,
/// it separates "there is no config yet" (a normal first-run state) from
/// "the config is there but broken", so callers can show the reason instead
/// of rendering blank fields.
public enum ConfigStore {
    /// The file's text. A missing file reads as "" (nothing configured yet);
    /// a file that exists but cannot be read throws `ConfigError.unreadable`.
    public static func text(at url: URL = Paths.config) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigError.unreadable(url.path)
        }
    }

    /// `text(at:)` for passive renders: an unreadable file is logged and reads as empty.
    public static func textOrLog(at url: URL = Paths.config) -> String {
        do {
            return try text(at: url)
        } catch {
            Log.warn("config", "could not read \(url.lastPathComponent): \(error.localizedDescription)")
            return ""
        }
    }

    /// The editable view of the config, or nil when there is nothing to show
    /// yet (missing or blank file). Throws when the file exists but cannot be
    /// read or is not a YAML mapping.
    public static func snapshot(at url: URL = Paths.config) throws -> GeneralConfigEditor.Snapshot? {
        let yaml = try text(at: url)
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try GeneralConfigEditor.snapshot(from: yaml)
    }
}
