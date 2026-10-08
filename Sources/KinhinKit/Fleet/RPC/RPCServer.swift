import Foundation
import Synchronization

// MARK: - Server

/// Line-delimited JSON over a unix socket. One request per connection keeps
/// the protocol trivially simple and robust.
enum RPCServer {

    /// Upper bound on simultaneously open connections (each holds a thread
    /// until answered, so an unbounded count is a local denial of service).
    static let maxConcurrentConnections = 32

    /// Serve requests forever on the given socket path.
    static func serve(
        socketURL: URL, handler: @escaping @Sendable (RPCRequest) async -> RPCResponse
    ) async throws {
        // A stale socket from a previous run may or may not exist; bind()
        // below reports any real problem if removal fails and the path is
        // still occupied.
        try? FileManager.default.removeItem(at: socketURL)
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The socket takes unauthenticated commands (stop, token swaps, VM
        // deletes): only the owning user may reach it.
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw RPCError.permissionsFailed(directory.path)
        }

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
        // chmod before listen: nothing can connect until then, so there is no
        // window where the socket is reachable with the default umask mode.
        guard chmod(socketURL.path, 0o600) == 0 else {
            close(fd)
            throw RPCError.permissionsFailed(socketURL.path)
        }
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw RPCError.listenFailed
        }

        // Mask signals on the accept loop; shutdown happens by unlinking.
        signal(SIGPIPE, SIG_IGN)

        let socketPath = socketURL.path
        let limiter = ConnectionLimiter(maximum: maxConcurrentConnections)
        // One blocking accept thread; each connection reads its request on
        // its own thread (bounded by `readTimeout`), so a slow or silent
        // client never stalls the next accept or a cooperative-pool thread.
        let acceptThread = Thread {
            var failures = 0
            while true {
                var len = socklen_t(MemoryLayout<sockaddr_un>.size)
                var clientAddr = sockaddr_un()
                let accepted = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        accept(fd, sa, &len)
                    }
                }
                if accepted < 0 {
                    let code = errno
                    // Socket closed by shutdown.
                    if !FileManager.default.fileExists(atPath: socketPath) { break }
                    // Anything else is transient (a signal, a reset client) or
                    // resource exhaustion (EMFILE/ENFILE): retrying at once
                    // would spin a core and flood the log, so back off.
                    failures += 1
                    if failures == 1 {
                        Log.warn("rpc", "accept failed (errno \(code)); retrying with backoff")
                    }
                    let delay = RPCServer.acceptRetryDelay(errno: code, consecutiveFailures: failures)
                    if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                    continue
                }
                failures = 0
                let clientFD = accepted
                // Only the daemon's own user (the socket is 0600, this is the
                // second line) and only a bounded number of live connections.
                guard peerIsCurrentUser(clientFD) else {
                    Log.warn("rpc", "dropped a connection from another user")
                    Darwin.close(clientFD)
                    continue
                }
                guard limiter.tryAcquire() else {
                    Log.warn("rpc", "dropped a connection: \(maxConcurrentConnections) already open")
                    Darwin.close(clientFD)
                    continue
                }
                let connection = Thread {
                    RPCServer.handleConnection(fd: clientFD, onClose: { limiter.release() }, handler: handler)
                }
                connection.name = "kinhin.rpc.connection"
                connection.start()
            }
        }
        acceptThread.name = "kinhin.rpc.accept"
        acceptThread.start()

        // Park this call forever — serving runs on the accept thread and the
        // per-connection threads. Returning would release the daemon lock.
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    /// How long the accept loop waits after a failed `accept`. A signal or an
    /// aborted connection retries at once; anything else (typically EMFILE
    /// with the process out of descriptors) doubles from 50 ms up to 1 s.
    static func acceptRetryDelay(errno code: Int32, consecutiveFailures: Int) -> TimeInterval {
        if code == EINTR || code == ECONNABORTED { return 0 }
        return min(1.0, 0.05 * pow(2, Double(min(max(consecutiveFailures, 1) - 1, 5))))
    }

    /// True when the peer of a unix-socket connection runs as our own user.
    static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }

    /// How long a request may run before the client is answered with a
    /// timeout error (the client's own default deadline is shorter).
    static let handlerTimeout: Duration = .seconds(120)

    /// How long a connection may take to send its request line. A client
    /// that connects and never writes is dropped after this.
    static let readTimeout: TimeInterval = 5

    /// Reads one request and answers it asynchronously. The descriptor is
    /// closed exactly once, by whichever of the handler or the timeout
    /// answers first — a late handler never writes to a descriptor number
    /// the kernel may already have reused for another client.
    static func handleConnection(
        fd: Int32,
        timeout: Duration = handlerTimeout,
        readTimeout: TimeInterval = readTimeout,
        onClose: (@Sendable () -> Void)? = nil,
        handler: @escaping @Sendable (RPCRequest) async -> RPCResponse
    ) {
        let reply = ConnectionReply(fd: fd, onClose: onClose)
        setReceiveTimeout(fd, readTimeout)
        guard let lineData = readLine(fd: fd) else {
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

    /// Reads up to the first newline. Nil when the peer sent nothing, the
    /// read failed, or it timed out (`SO_RCVTIMEO`) — a raw `read` instead of
    /// `FileHandle.availableData`, which raises on a timed-out read.
    static func readLine(fd: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            if count < 0 { return nil }
            if count == 0 { return buffer.isEmpty ? nil : buffer }
            buffer.append(contentsOf: chunk[0..<count])
            if buffer.last == 0x0A { return buffer }
            if buffer.count > 1_000_000 { return nil }  // sanity cap
        }
    }

    static func setReceiveTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size)) != 0 {
            Log.warn("rpc", "could not set a read timeout on a connection (errno \(errno))")
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
    private let onClose: (@Sendable () -> Void)?

    init(fd: Int32, onClose: (@Sendable () -> Void)? = nil) {
        self.fd = fd
        self.onClose = onClose
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
            onClose?()
            return true
        }
    }
}

// MARK: - Connection limit

/// Counts live connections against a fixed maximum.
final class ConnectionLimiter: Sendable {
    private let maximum: Int
    private let live = Mutex(0)

    init(maximum: Int) {
        self.maximum = maximum
    }

    /// Reserves a slot; false when `maximum` connections are already open.
    func tryAcquire() -> Bool {
        live.withLock { count in
            guard count < maximum else { return false }
            count += 1
            return true
        }
    }

    func release() {
        live.withLock { $0 = max(0, $0 - 1) }
    }
}
