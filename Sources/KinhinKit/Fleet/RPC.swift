import Foundation

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
    public let pat: String
    public init(pat: String) { self.pat = pat }
}

/// Payload for `replace_gitea_token`: swaps the daemon's Gitea access token.
struct GiteaTokenReplaceRequest: Codable, Sendable, Equatable {
    public let token: String
    public init(token: String) { self.token = token }
}

/// Payload for `replace_forgejo_token`: swaps the daemon's Forgejo access token.
struct ForgejoTokenReplaceRequest: Codable, Sendable, Equatable {
    public let token: String
    public init(token: String) { self.token = token }
}

/// Payload for `replace_account_token`: swaps one account's token.
struct AccountTokenReplaceRequest: Codable, Sendable, Equatable {
    public let account: String
    public let token: String
    public init(account: String, token: String) {
        self.account = account
        self.token = token
    }
}

struct RPCRequest: Codable, Sendable, Equatable {
    public let id: Int
    public let method: RPCMethod
    public let payload: Data?

    public init(id: Int, method: RPCMethod, payload: Data? = nil) {
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

public enum RPCPaths {
    /// Daemon listens on this unix socket.
    public static var socket: URL {
        Paths.appSupport.appendingPathComponent("daemon.sock")
    }
}

/// Line-delimited JSON over a unix socket. One request per connection keeps
/// the protocol trivially simple and robust.
enum RPCServer {
    /// Serve requests forever on the given socket path.
    public static func serve(socketURL: URL, handler: @escaping @Sendable (RPCRequest) async -> RPCResponse) throws {
        // A stale socket from a previous run may or may not exist; bind()
        // below reports any real problem.
        try? FileManager.default.removeItem(at: socketURL)
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RPCError.socketCreateFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8)
        guard pathBytes.count < 104 else { throw RPCError.socketPathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            dest.copyBytes(from: pathBytes)
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw RPCError.bindFailed(socketURL.path)
        }
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw RPCError.listenFailed
        }

        // Mask signals on the accept loop; shutdown happens by unlinking.
        signal(SIGPIPE, SIG_IGN)

        let socketPath = socketURL.path
        // One blocking accept thread; each connection is handled on its own
        // task, so a slow reader never stalls the next accept.
        let acceptThread = Thread {
            while true {
                var len = socklen_t(MemoryLayout<sockaddr_un>.size)
                var clientAddr = sockaddr_un()
                let accepted = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        accept(fd, sa, &len)
                    }
                }
                if accepted < 0 {
                    // Socket closed by shutdown.
                    if FileManager.default.fileExists(atPath: socketPath) {
                        continue
                    }
                    break
                }
                let clientFD = accepted
                Task {
                    RPCServer.handleConnection(fd: clientFD, handler: handler)
                }
            }
        }
        acceptThread.name = "kinhin.rpc.accept"
        acceptThread.start()

        // Park this call forever — serving runs on the accept thread and the
        // per-connection tasks. Returning would release the daemon lock.
        dispatchMain()
    }

    /// How long a request may run before the client is answered with a
    /// timeout error (the client's own default deadline is shorter).
    static let handlerTimeout: Duration = .seconds(120)

    /// Reads one request and answers it asynchronously. The descriptor is
    /// closed exactly once, by whichever of the handler or the timeout
    /// answers first — a late handler never writes to a descriptor number
    /// the kernel may already have reused for another client.
    static func handleConnection(
        fd: Int32,
        timeout: Duration = handlerTimeout,
        handler: @escaping @Sendable (RPCRequest) async -> RPCResponse
    ) {
        let reply = ConnectionReply(fd: fd)
        guard let lineData = readLine(from: reply.file) else {
            reply.close()
            return
        }

        let decoder = JSONDecoder()
        let request: RPCRequest
        do {
            request = try decoder.decode(RPCRequest.self, from: lineData)
        } catch {
            Log.warn("rpc", "undecodable request: \(error)")
            reply.send(RPCResponse(id: -1, ok: false, error: "undecodable request"))
            return
        }

        let method = request.method.rawValue
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return  // cancelled: the handler answered first
            }
            let timedOut = RPCResponse(id: request.id, ok: false, error: "daemon timed out handling \(method)")
            if reply.send(timedOut) {
                Log.warn("rpc", "\(method) did not finish within \(timeout); answered with a timeout")
            }
        }
        // The handler is not cancelled on timeout: daemon operations (stop,
        // token swaps) must run to completion; only the late reply is dropped.
        Task {
            let response = await handler(request)
            timer.cancel()
            if !reply.send(response) {
                Log.warn("rpc", "dropping late \(method) response (client already got a timeout)")
            }
        }
    }

    /// The peer may have hung up; a failed write is logged, not fatal.
    static func write(_ data: Data, to file: FileHandle) {
        do {
            try file.write(contentsOf: data)
        } catch {
            Log.warn("rpc", "could not write response: \(error.localizedDescription)")
        }
    }

    static func responseLine(_ response: RPCResponse) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data: Data
        do {
            data = try encoder.encode(response)
        } catch {
            Log.error("rpc", "could not encode response: \(error)")
            data = Data("{}".utf8)
        }
        data.append(0x0A)  // newline framing
        return data
    }

    static func readLine(from handle: FileHandle) -> Data? {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return buffer.isEmpty ? nil : buffer }
            buffer.append(chunk)
            if buffer.last == 0x0A { return buffer }
            if buffer.count > 1_000_000 { return nil }  // sanity cap
        }
    }
}

// MARK: - Connection reply

/// One accepted connection's single answer. The first `send` or `close`
/// wins; it writes (if sending) and closes the descriptor. Later calls are
/// no-ops, so the descriptor is never touched after it is closed.
final class ConnectionReply: Sendable {
    let file: FileHandle
    private let fd: Int32
    private let finished = Mutex(false)

    init(fd: Int32) {
        self.fd = fd
        self.file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    }

    /// Writes `response` and closes. Returns false when the connection was
    /// already answered or closed.
    @discardableResult
    func send(_ response: RPCResponse) -> Bool {
        finish { RPCServer.write(RPCServer.responseLine(response), to: file) }
    }

    /// Closes without answering (the peer sent nothing).
    func close() {
        finish {}
    }

    @discardableResult
    private func finish(_ body: () -> Void) -> Bool {
        finished.withLock { done in
            guard !done else { return false }
            done = true
            body()
            Darwin.close(fd)
            return true
        }
    }
}

public enum RPCError: LocalizedError {
    case socketCreateFailed
    case bindFailed(String)
    case listenFailed
    case socketPathTooLong
    case connectionFailed(String)
    case timeout
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .socketCreateFailed: return "could not create unix socket"
        case .bindFailed(let path): return "could not bind socket at \(path) (is another daemon running?)"
        case .listenFailed: return "could not listen on socket"
        case .socketPathTooLong: return "socket path too long"
        case .connectionFailed(let path): return "could not connect to daemon at \(path) — is `kinhin daemon` running?"
        case .timeout: return "daemon did not answer in time"
        case .rejected(let why): return "daemon rejected the request: \(why)"
        }
    }
}

/// Client for talking to a running daemon.
public struct RPCClient: Sendable {
    let socketURL: URL

    public init(socketURL: URL = RPCPaths.socket) {
        self.socketURL = socketURL
    }

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
