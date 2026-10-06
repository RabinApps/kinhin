import Foundation
import Synchronization

@testable import KinhinKit

/// A shell double that models `docker ps/run/start/rm` as real state: `run
/// --name X` creates container X, `start X` ensures it is present, `rm
/// --force X` removes it, and `ps`/`ps -a` return the current names — so
/// provision, awaitRunning, and recovery behave like the real CLI. Other
/// argvs (including `exec`) return success and record the delivered script on
/// stdin so tests can inspect the registration script the runtime shipped.
///
/// Queued `ps`/`ps -a` responses let a test model a slow start without a
/// private state machine; queued `exec` results let a test force a registration
/// failure; `seedContainer` lays down state for the recovery path to adopt the
/// way it adopts a stray the real CLI reports.
final class DockerFakingShell: ShellRunning, Sendable {
    private struct State: Sendable {
        var argvs: [[String]] = []
        var containers: Set<String> = []

        var psResponses: [String] = []
        var execResults: [ShellResult] = []

        mutating func handle(_ argv: [String]) -> ShellResult {
            argvs.append(argv)
            guard argv.first?.hasSuffix("/docker") == true || argv.first == "docker" else {
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
            let verb = argv.dropFirst().first
            switch verb {
            case "ps":
                if let head = psResponses.first {
                    psResponses.removeFirst()
                    if !head.isEmpty {
                        return ShellResult(exitCode: 0, stdout: head, stderr: "")
                    }
                }
                return ShellResult(
                    exitCode: 0,
                    stdout: containers.sorted().joined(separator: "\n"),
                    stderr: "")
            case "run":
                if let nameIndex = argv.firstIndex(of: "--name"), argv.indices.contains(nameIndex + 1) {
                    containers.insert(argv[nameIndex + 1])
                }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            case "start":
                if let name = argv.last { containers.insert(name) }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            case "rm":
                if let name = argv.last { containers.remove(name) }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            default:
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        }

        mutating func handleExec(_ argv: [String], stdin: String) -> ShellResult {
            argvs.append(argv + ["<stdin>", stdin])
            guard argv.first?.hasSuffix("/docker") == true || argv.first == "docker" else {
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
            if argv.dropFirst().first == "exec", let head = execResults.first {
                execResults.removeFirst()
                return head
            }
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private let state = Mutex(State())

    func seedContainer(named name: String) {
        _ = state.withLock { $0.containers.insert(name) }
    }

    var psResponses: [String] {
        get { state.withLock { $0.psResponses } }
        set { state.withLock { $0.psResponses = newValue } }
    }

    var execResults: [ShellResult] {
        get { state.withLock { $0.execResults } }
        set { state.withLock { $0.execResults = newValue } }
    }
    var containers: Set<String> {
        state.withLock { $0.containers }
    }

    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        state.withLock { $0.handle(argv) }
    }

    func run(_ argv: [String], input: Data, cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        let stdin = String(decoding: input, as: UTF8.self)
        let cleanArgv = argv.last == "<stdin>" ? Array(argv.dropLast(2)) : argv
        return state.withLock { $0.handleExec(cleanArgv, stdin: stdin) }
    }

    func argvSnapshot() -> [[String]] {
        state.withLock { $0.argvs }
    }
}
