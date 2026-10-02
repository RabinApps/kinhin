import Foundation

public enum ConfigError: LocalizedError, Equatable {
    case missing(String)
    case invalid(String)
    case notFound(String)
    case unreadable(String)
    case projectNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let key): return "config: missing required key '\(key)'"
        case .invalid(let why): return "config: \(why)"
        case .notFound(let path): return "config not found at \(path) — run `kinhin config init` to create one"
        case .unreadable(let path): return "config could not be read at \(path)"
        case .projectNotFound(let path): return "project directory not found at \(path)"
        }
    }
}
