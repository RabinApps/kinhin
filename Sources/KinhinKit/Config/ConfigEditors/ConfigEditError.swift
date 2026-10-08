import Foundation

/// Errors from every config editor (whole-file, general, labels, runtimes,
/// toolchains). One type so callers can handle "the edit was rejected" once.
public enum ConfigEditError: LocalizedError, Equatable {
    /// No config file exists at this path.
    case notFound(String)
    /// The file (or edited text) is not valid YAML.
    case yamlParse(String)
    /// The edited result failed `ConfigLoader.parse`; nothing was written.
    case validation(String)
    /// The whole-file editor rejected the text; nothing was saved.
    case rejected(String)
    /// The edit is not supported for this config shape.
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path): return "config not found at \(path)"
        case .yamlParse(let why): return "config is not valid YAML — \(why)"
        case .validation(let why): return why
        case .rejected(let why): return "config validation failed — nothing was saved:\n\n\(why)"
        case .unsupported(let what): return what
        }
    }
}

// MARK: - Decoding failures

extension ConfigEditError {
    /// A typed decode of the config failed (a key holds the wrong kind of
    /// value). Names the offending key path instead of Foundation's generic
    /// "data isn't in the correct format".
    static func decoding(_ error: Error) -> ConfigEditError {
        guard let decoding = error as? DecodingError else { return .validation(error.localizedDescription) }
        return .validation(decoding.configDescription)
    }
}
