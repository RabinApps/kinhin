import Foundation

/// Whole-file config editing for the app's in-UI editor. Unlike the section
/// editors (RuntimesConfigEditor, LabelsConfigEditor) that rewrite one
/// top-level key in place, this takes the user's full edited text and writes
/// it — but only when the result parses through `ConfigLoader.parse`, the
/// same validation the engine itself applies on boot. A bad edit therefore
/// never lands on disk: the caller shows the error and the file keeps its
/// previous content.
public enum ConfigEditor {
    public enum ConfigEditorError: LocalizedError, Equatable {
        case notFound(String)
        case validation(String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let path):
                return "config not found at \(path)"
            case .validation(let why):
                return "config validation failed — nothing was saved:\n\n\(why)"
            }
        }
    }

    /// Writes the edited YAML if (and only if) it parses cleanly. Returns
    /// the text that was written (identical to the input on success).
    @discardableResult
    public static func save(_ yaml: String, to url: URL = Paths.config) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigEditorError.notFound(url.path)
        }
        do {
            _ = try ConfigLoader.parse(yaml)
        } catch {
            throw ConfigEditorError.validation(error.localizedDescription)
        }
        try yaml.write(toFile: url.path, atomically: true, encoding: .utf8)
        return yaml
    }
}
