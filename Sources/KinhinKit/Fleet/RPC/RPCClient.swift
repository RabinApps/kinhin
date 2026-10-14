import Foundation

// MARK: - Client

/// Client for talking to a running daemon.
public struct RPCClient: Sendable {
    let socketURL: URL

    public init(socketURL: URL = RPCPaths.socket) {
        self.socketURL = socketURL
    }

    /// An unreachable or misbehaving daemon simply reads as "not alive";
    /// callers only branch on the boolean. The ping gets a short deadline:
    /// a wedged daemon must not stall app launch or a CLI command.
    public static func isDaemonAlive(socketURL: URL = RPCPaths.socket) -> Bool {
        guard FileManager.default.fileExists(atPath: socketURL.path) else { return false }
        do {
            return try RPCClient(socketURL: socketURL).send(method: .ping, timeout: 2).ok
        } catch {
            return false
        }
    }

    /// Runs blocking client calls on a dedicated thread and resumes the
    /// caller with the result, so an async caller (the app's main actor, the
    /// cooperative pool) never waits on the socket itself:
    /// `try await client.perform { try $0.status() }`.
    @discardableResult
    public func perform<T: Sendable>(_ body: @escaping @Sendable (RPCClient) throws -> T) async throws -> T {
        let client = self
        return try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result { try body(client) })
            }
            thread.name = "kinhin.rpc.client"
            thread.start()
        }
    }

    /// Pings the daemon. A daemon that predates the protocol/version fields
    /// answers `pong` only: those come back nil.
    public func ping(timeout: TimeInterval = 2) throws -> PingReply {
        let response = try Self.requireOK(send(method: .ping, timeout: timeout))
        guard let payload = response.payload,
            let reply = try? JSONDecoder().decode(PingReply.self, from: payload)
        else { return PingReply(pong: true, protocolVersion: nil, version: nil) }
        return reply
    }

    /// The daemon's fleet status.
    /// `includeUsage: false` asks the daemon to skip CPU/RAM sampling (the
    /// request then carries a payload; the default sends none, exactly as
    /// before, so any daemon version understands it).
    public func status(includeUsage: Bool = true) throws -> FleetStatus {
        let payload = includeUsage ? nil : try JSONEncoder().encode(Daemon.StatusRequest(includeUsage: false))
        let response = try command(.status, payload: payload)
        guard let payload = response.payload else { throw RPCError.rejected("daemon returned no status payload") }
        return try JSONDecoder().decode(FleetStatus.self, from: payload)
    }

    /// The live pipeline `vmID` is running, or nil when it runs none (or the
    /// daemon predates the call: it answers a decode error, never a payload).
    public func pipelineDetail(vmID: String) throws -> PipelineDetail? {
        let payload = try JSONEncoder().encode(Daemon.VMDeleteRequest(id: vmID))
        let response = try command(.pipelineDetail, payload: payload)
        guard let data = response.payload else { return nil }
        return try JSONDecoder().decode(PipelineDetail.self, from: data)
    }

    /// The output of a step (or job, with no `stepIndex`) of `vmID`'s pipeline;
    /// nil when there is none to show.
    public func pipelineLog(vmID: String, jobID: String, stepIndex: Int?) throws -> PipelineLog? {
        let payload = try JSONEncoder().encode(
            Daemon.PipelineLogRequest(id: vmID, jobID: jobID, stepIndex: stepIndex))
        let response = try command(.pipelineLog, payload: payload)
        guard let data = response.payload else { return nil }
        return try JSONDecoder().decode(PipelineLog.self, from: data)
    }

    /// Starts a benchmark run in the daemon and returns its run id. A daemon that predates benchmarks
    /// does not know the method and says so.
    public func benchStart(_ options: BenchmarkOptions) throws -> String {
        do {
            let response = try command(.benchStart, payload: JSONEncoder().encode(options))
            guard let payload = response.payload else { throw RPCError.rejected("daemon returned no run id") }
            return try JSONDecoder().decode(Daemon.BenchStartReply.self, from: payload).runID
        } catch RPCError.rejected("undecodable request") {
            throw BenchmarkError.unsupported("this daemon predates benchmarks — restart it after updating kinhin")
        }
    }

    /// The status of a benchmark run (the most recent when `runID` is nil).
    public func benchStatus(runID: String?) throws -> BenchmarkRunStatus {
        let response = try command(.benchStatus, payload: JSONEncoder().encode(Daemon.BenchStatusRequest(runID: runID)))
        guard let payload = response.payload else { throw RPCError.rejected("daemon returned no benchmark status") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BenchmarkRunStatus.self, from: payload)
    }

    /// Cancels a running benchmark (the latest when `runID` is nil); false when none is running.
    @discardableResult
    public func benchCancel(runID: String?) throws -> Bool {
        do {
            try command(.benchCancel, payload: JSONEncoder().encode(Daemon.BenchStatusRequest(runID: runID)))
            return true
        } catch RPCError.rejected(let why) where why.contains("no benchmark run") {
            return false
        }
    }

    /// The healing agent's policy and journal. A daemon that predates healing
    /// does not know the method and says so.
    public func healingStatus() throws -> HealingSnapshot {
        do {
            let response = try command(.healingStatus)
            guard let payload = response.payload else { throw RPCError.rejected("daemon returned no healing status") }
            return try JSONDecoder().decode(HealingSnapshot.self, from: payload)
        } catch RPCError.rejected("undecodable request") {
            throw RPCError.rejected("this daemon predates healing — restart it after updating kinhin")
        }
    }

    /// Approves (`approve: true`) or dismisses a healing event.
    public func healingDecide(id: String, approve: Bool) throws {
        do {
            try command(
                approve ? .healingApprove : .healingDismiss,
                payload: JSONEncoder().encode(Daemon.HealingEventRequest(id: id)))
        } catch RPCError.rejected("undecodable request") {
            throw RPCError.rejected("this daemon predates healing — restart it after updating kinhin")
        }
    }

    /// Ask the daemon to swap its PAT (it must already be in the Keychain).
    public func replaceToken(pat: String) throws {
        try command(.replaceToken, payload: JSONEncoder().encode(TokenReplaceRequest(pat: pat)))
    }

    /// Ask the daemon to swap one account's token (already in the Keychain).
    public func replaceAccountToken(account: String, token: String) throws {
        try command(
            .replaceAccountToken,
            payload: JSONEncoder().encode(AccountTokenReplaceRequest(account: account, token: token)))
    }

    /// Ask the daemon to reload config.yaml. The file is the source of
    /// truth — it was already validated before being written.
    public func reloadConfig() throws {
        try command(.reloadConfig)
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
