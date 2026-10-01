import Foundation

// MARK: - Wire types

/// All RPC methods the daemon serves.
public enum RPCMethod: String, Codable, Sendable {
    case status
    case start
    case stop
    case pause
    case resume
    case deleteVM = "delete_vm"
    case replaceToken = "replace_token"
    case replaceGiteaToken = "replace_gitea_token"
    case replaceForgejoToken = "replace_forgejo_token"
    /// Swap the token of one named account (multi-account configs).
    case replaceAccountToken = "replace_account_token"
    /// Reload the routing config from disk (the Runtimes pane's edit hook).
    case reloadConfig = "reload_config"
    case logs
    case ping
}

/// Payload for `replace_token`: swaps the daemon's PAT without a restart.
struct TokenReplaceRequest: Codable, Sendable, Equatable {
    let pat: String
    init(pat: String) { self.pat = pat }
}

/// Payload for `replace_gitea_token`: swaps the daemon's Gitea access token.
struct GiteaTokenReplaceRequest: Codable, Sendable, Equatable {
    let token: String
    init(token: String) { self.token = token }
}

/// Payload for `replace_forgejo_token`: swaps the daemon's Forgejo access token.
struct ForgejoTokenReplaceRequest: Codable, Sendable, Equatable {
    let token: String
    init(token: String) { self.token = token }
}

/// Payload for `replace_account_token`: swaps one account's token.
struct AccountTokenReplaceRequest: Codable, Sendable, Equatable {
    let account: String
    let token: String
    init(account: String, token: String) {
        self.account = account
        self.token = token
    }
}

struct RPCRequest: Codable, Sendable, Equatable {
    let id: Int
    let method: RPCMethod
    let payload: Data?

    init(id: Int, method: RPCMethod, payload: Data? = nil) {
        self.id = id
        self.method = method
        self.payload = payload
    }
}

public struct RPCResponse: Codable, Sendable, Equatable {
    public let id: Int
    public let ok: Bool
    public let payload: Data?
    public let error: String?

    public init(id: Int, ok: Bool, payload: Data? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.payload = payload
        self.error = error
    }
}

// MARK: - Error

public enum RPCError: LocalizedError {
    case socketCreateFailed
    case bindFailed(String)
    case listenFailed
    case socketPathTooLong
    case permissionsFailed(String)
    case connectionFailed(String)
    case timeout
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .socketCreateFailed: return "could not create unix socket"
        case .bindFailed(let path): return "could not bind socket at \(path) (is another daemon running?)"
        case .listenFailed: return "could not listen on socket"
        case .socketPathTooLong: return "socket path too long"
        case .permissionsFailed(let path): return "could not restrict \(path) to the current user"
        case .connectionFailed(let path): return "could not connect to daemon at \(path) — is `kinhin daemon` running?"
        case .timeout: return "daemon did not answer in time"
        case .rejected(let why): return "daemon rejected the request: \(why)"
        }
    }
}

// MARK: - Paths

public enum RPCPaths {
    /// Daemon listens on this unix socket.
    public static var socket: URL {
        Paths.appSupport.appendingPathComponent("daemon.sock")
    }
}
