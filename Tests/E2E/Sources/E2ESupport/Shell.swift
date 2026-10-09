import Foundation

/// The outcome of one finished process.
public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    /// The run hit its time limit and was terminated.
    public let timedOut: Bool

    public var ok: Bool { status == 0 && !timedOut }
    public var output: String { stdout + stderr }
    public var trimmedStdout: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Thread-safe growing buffer for a pipe's bytes.
private final class Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

public enum Shell {
    /// Directories searched in addition to the inherited PATH (Homebrew, Docker Desktop).
    static let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public static func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = extraPath + ":" + (env["PATH"] ?? "")
        return env
    }

    /// Runs `executable` (a path, or a bare name resolved through PATH) and waits for it.
    @discardableResult
    public static func run(
        _ executable: String, _ arguments: [String] = [], environment: [String: String]? = nil, cwd: String? = nil,
        stdin: String? = nil, timeout: TimeInterval = 120
    ) async throws -> ProcessResult {
        let process = Process()
        let env = environment ?? baseEnvironment()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        process.environment = env
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let out = Pipe()
        let err = Pipe()
        let inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = inPipe
        let outBuffer = Buffer()
        let errBuffer = Buffer()
        out.fileHandleForReading.readabilityHandler = { outBuffer.append($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { errBuffer.append($0.availableData) }

        let timedOut = TimedOut()
        let timer = DispatchWorkItem {
            timedOut.set()
            process.terminate()
        }
        // The handler is installed before the launch, so a process that exits at once cannot be missed.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? inPipe.fileHandleForWriting.close()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        timer.cancel()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        // Whatever the handlers had not drained yet.
        outBuffer.append((try? out.fileHandleForReading.readToEnd()) ?? Data())
        errBuffer.append((try? err.fileHandleForReading.readToEnd()) ?? Data())
        return ProcessResult(
            status: process.terminationStatus, stdout: outBuffer.string, stderr: errBuffer.string,
            timedOut: timedOut.value)
    }

    private final class TimedOut: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.withLock { flag = true } }
        var value: Bool { lock.withLock { flag } }
    }

    /// True when `tool` launches (`tool` + `args` exits 0).
    public static func available(_ tool: String, _ args: [String] = ["--version"]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + args
        process.environment = baseEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// Polls `condition` until it returns a value, or throws when `timeout` passes.
public func eventually<T: Sendable>(
    _ what: String, timeout: TimeInterval, interval: TimeInterval = 2,
    _ condition: @Sendable () async throws -> T?
) async throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if let value = try await condition() { return value }
        guard Date() < deadline else { throw E2EError.timedOut(what, after: timeout) }
        try await Task.sleep(for: .seconds(interval))
    }
}

public enum E2EError: Error, CustomStringConvertible {
    case timedOut(String, after: TimeInterval)
    case failed(String)
    case unavailable(String)

    public var description: String {
        switch self {
        case .timedOut(let what, let after): return "timed out after \(Int(after))s waiting for \(what)"
        case .failed(let message): return message
        case .unavailable(let message): return "unavailable: \(message)"
        }
    }
}
