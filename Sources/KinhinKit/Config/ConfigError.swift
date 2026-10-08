import Foundation

public enum ConfigError: LocalizedError, Equatable {
    case missing(String)
    case invalid(String)
    case notFound(String)
    /// The file exists but reading it failed; `reason` is the underlying cause
    /// (permissions, not UTF-8, is a directory, ...).
    case unreadable(String, reason: String)
    case projectNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let key): return "config: missing required key '\(key)'"
        case .invalid(let why): return "config: \(why)"
        case .notFound(let path): return "config not found at \(path) — run `kinhin config init` to create one"
        case .unreadable(let path, let reason): return "config could not be read at \(path): \(reason)"
        case .projectNotFound(let path): return "project directory not found at \(path)"
        }
    }
}

// MARK: - Decoding failures

extension DecodingError {
    /// A one-line description naming the offending config key path (`vm.cpu`,
    /// `accounts[0].scope`) instead of Foundation's generic "data isn't in the
    /// correct format". Coding keys are the YAML keys, so the path is what the
    /// user typed.
    var configDescription: String {
        func path(_ context: Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.isEmpty ? "config" : keys.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
        }
        switch self {
        case .typeMismatch(let type, let context):
            return "\(path(context)) must be \(type)"
        case .valueNotFound(let type, let context):
            return "\(path(context)) must be \(type), found nothing"
        case .keyNotFound(let key, let context):
            return "\(path(context)) is missing \(key.stringValue)"
        case .dataCorrupted(let context):
            return "\(path(context)): \(context.debugDescription)"
        @unknown default:
            return localizedDescription
        }
    }
}
