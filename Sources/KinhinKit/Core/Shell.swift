import Foundation

/// A completed subprocess run.
public struct ShellResult: Sendable {
    let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }

    /// Non-empty, whitespace-trimmed lines of stdout (ids, names, references).
    var outputLines: [String] {
        stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

enum ShellError: LocalizedError {
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let why): return "Failed to launch process: \(why)"
        }
    }
}

/// Runs subprocesses. Injectable so tests can script fake tool output.
public protocol ShellRunning: Sendable {
    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult
}

public extension ShellRunning {
    func run(_ argv: [String]) async throws -> ShellResult {
        try await run(argv, cwd: nil, timeout: 120)
    }
}

/// Real shell runner using Foundation's Process.
public struct Shell: ShellRunning {
    public init() {}

    public func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        guard let first = argv.first else {
            throw ShellError.launchFailed("empty argv")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: first)
        process.arguments = Array(argv.dropFirst())
        if let cwd {
            process.currentDirectoryURL = cwd
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Detach stdin: subprocesses must never wait on us.
        process.standardInput = FileHandle.nullDevice

        // Accumulate concurrently so large outputs cannot deadlock the pipes.
        let outData = DataAccumulator()
        let errData = DataAccumulator()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            outData.append(handle.availableData)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            errData.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed("\(first): \(error.localizedDescription)")
        }

        // Timeout watchdog.
        let timedOut = Box(false)
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timedOut.value = true
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        process.waitUntilExit()

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        // Drain any final buffered bytes.
        outData.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        errData.append(errPipe.fileHandleForReading.readDataToEndOfFile())

        let code = process.terminationStatus
        let actual = timedOut.value ? Int32(124) : code  // 124 = timeout convention
        return ShellResult(
            exitCode: actual,
            stdout: outData.text,
            stderr: errData.text
        )
    }
}
