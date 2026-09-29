import Foundation
import Synchronization

// MARK: - Server

/// Line-delimited JSON over a unix socket. One request per connection keeps
/// the protocol trivially simple and robust.
enum RPCServer {
    /// Serve requests forever on the given socket path.
    public static func serve(socketURL: URL, handler: @escaping @Sendable (RPCRequest) async -> RPCResponse) throws {
        // A stale socket from a previous run may or may not exist; bind()
        // below reports any real problem if removal fails and the path is
        // still occupied.
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
