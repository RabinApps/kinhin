import Foundation

// MARK: - Client

/// Client for talking to a running daemon.
public struct RPCClient: Sendable {
    let socketURL: URL

    public init(socketURL: URL = RPCPaths.socket) {
        self.socketURL = socketURL
    }

    /// An unreachable or misbehaving daemon simply reads as "not alive";
    /// callers only branch on the boolean.
    public static func isDaemonAlive(socketURL: URL = RPCPaths.socket) -> Bool {
        guard FileManager.default.fileExists(atPath: socketURL.path) else { return false }
        return (try? RPCClient(socketURL: socketURL).ping()) != nil
    }

    @discardableResult
    func ping() throws -> Bool {
        let response = try send(method: .ping)
        return response.ok
    }

    /// Ask the daemon to swap its PAT (it must already be in the Keychain).
    @discardableResult
    public func replaceToken(pat: String) throws -> Bool {
        let payload = try JSONEncoder().encode(TokenReplaceRequest(pat: pat))
        let response = try send(method: .replaceToken, payload: payload)
        guard response.ok else {
            throw RPCError.rejected(response.error ?? "unknown error")
        }
        return true
    }

    /// Ask the daemon to swap its Gitea access token.
    @discardableResult
    public func replaceGiteaToken(_ token: String) throws -> Bool {
        let payload = try JSONEncoder().encode(GiteaTokenReplaceRequest(token: token))
        let response = try send(method: .replaceGiteaToken, payload: payload)
        guard response.ok else {
            throw RPCError.rejected(response.error ?? "unknown error")
        }
        return true
    }

    /// Ask the daemon to swap its Forgejo access token.
    @discardableResult
    public func replaceForgejoToken(_ token: String) throws -> Bool {
        let payload = try JSONEncoder().encode(ForgejoTokenReplaceRequest(token: token))
        let response = try send(method: .replaceForgejoToken, payload: payload)
        guard response.ok else {
            throw RPCError.rejected(response.error ?? "unknown error")
        }
        return true
    }

    /// Ask the daemon to swap one account's token (already in the Keychain).
    @discardableResult
    public func replaceAccountToken(account: String, token: String) throws -> Bool {
        let payload = try JSONEncoder().encode(AccountTokenReplaceRequest(account: account, token: token))
        let response = try send(method: .replaceAccountToken, payload: payload)
        guard response.ok else {
            throw RPCError.rejected(response.error ?? "unknown error")
        }
        return true
    }

    /// Ask the daemon to reload the routing config from disk (runtimes
    /// section changed). The file is the source of truth — it was already
    /// validated before being written.
    @discardableResult
    public func reloadConfig() throws -> Bool {
        let response = try send(method: .reloadConfig)
        guard response.ok else {
            throw RPCError.rejected(response.error ?? "unknown error")
        }
        return true
    }

    /// Like `send`, but a response the daemon rejected (`ok == false`) throws
    /// `RPCError.rejected` — for callers that only care whether the command worked.
    @discardableResult
    public func command(_ method: RPCMethod, payload: Data? = nil) throws -> RPCResponse {
        try Self.requireOK(send(method: method, payload: payload))
    }

    static func requireOK(_ response: RPCResponse) throws -> RPCResponse {
        guard response.ok else { throw RPCError.rejected(response.error ?? "unknown error") }
        return response
    }

    public func send(method: RPCMethod, payload: Data? = nil, timeout: TimeInterval = 60) throws -> RPCResponse {
        guard FileManager.default.fileExists(atPath: socketURL.path) else {
            throw RPCError.connectionFailed(socketURL.path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RPCError.connectionFailed(socketURL.path) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8)
        guard pathBytes.count < 104 else { throw RPCError.socketPathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            dest.copyBytes(from: pathBytes)
        }
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw RPCError.connectionFailed(socketURL.path) }

        let request = RPCRequest(id: Int.random(in: 1...1_000_000), method: method, payload: payload)
        let encoder = JSONEncoder()
        var line = try encoder.encode(request)
        line.append(0x0A)

        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try file.write(contentsOf: line)

        // Blocking read with deadline via poll().
        var deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 1000)
            if ready > 0 {
                let chunk = file.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                if buffer.last == 0x0A { break }
            }
        }
        deadline = Date()
        guard buffer.last == 0x0A, !buffer.isEmpty else { throw RPCError.timeout }

        return try JSONDecoder().decode(RPCResponse.self, from: buffer)
    }
}
