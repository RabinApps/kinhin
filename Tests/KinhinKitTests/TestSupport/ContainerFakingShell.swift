import Foundation
import Synchronization

@testable import KinhinKit

/// A shell double that models `container list` as real state: `run --name X`
/// creates container X, `delete --force X` removes it, and list returns the
/// current names — so provision/awaitRunning/provision-after-recovery behave
/// like the real CLI. `inspect X` prints a running container's JSON (state and
/// an IPv4 address on the container network, numbered in creation order) or
/// fails with the CLI's "container not found" for an unknown name. `image list`
/// prints the images `setImages` stored (one per line, like `container image
/// list --quiet`), or fails after `failImageList()`. An `exec` whose script
/// contains a needle given to `answerExec` prints that answer on stdout. Other
/// argvs return success. Matches the binary on any install prefix so the test
/// stays independent of the host PATH.
final class ContainerFakingShell: ShellRunning, Sendable {
    private struct State: Sendable {
        var argvs: [[String]] = []
        var containers: Set<String> = []
        /// Each created container's last address octet, in creation order (192.168.64.2 first, like the CLI).
        var addresses: [String: Int] = [:]
        var images: [String] = []
        var imageListFails = false
        var execAnswers: [(needle: String, stdout: String)] = []

        mutating func handle(_ argv: [String]) -> ShellResult {
            argvs.append(argv)
            guard
                argv.first == nil || argv.first == "/usr/local/bin/container"
                    || argv.first?.hasSuffix("container") == true
            else {
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
            switch argv.dropFirst().first {
            case "list":
                return ShellResult(exitCode: 0, stdout: containers.joined(separator: "\n"), stderr: "")
            case "run":
                if let nameIdx = argv.firstIndex(of: "--name"), argv.count > nameIdx + 1 {
                    let name = argv[nameIdx + 1]
                    containers.insert(name)
                    if addresses[name] == nil { addresses[name] = addresses.count + 2 }
                }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            case "inspect":
                guard let name = argv.last, containers.contains(name) else {
                    return ShellResult(
                        exitCode: 1, stdout: "", stderr: "Error: container not found: \(argv.last ?? "")")
                }
                let address = "192.168.64.\(addresses[name] ?? 2)/24"
                return ShellResult(
                    exitCode: 0,
                    stdout:
                        #"[{"id":"\#(name)","status":{"state":"running","networks":[{"ipv4Address":"\#(address)"}]}}]"#,
                    stderr: "")
            case "exec":
                let script = argv.last ?? ""
                let answer = execAnswers.first { script.contains($0.needle) }
                return ShellResult(exitCode: 0, stdout: answer?.stdout ?? "", stderr: "")
            case "start":
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            case "image" where argv.dropFirst(2).first == "list":
                if imageListFails { return ShellResult(exitCode: 1, stdout: "", stderr: "XPC connection error") }
                return ShellResult(exitCode: 0, stdout: images.joined(separator: "\n"), stderr: "")
            case "delete":
                if let last = argv.last { containers.remove(last) }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            default:
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        }
    }

    private let state = Mutex(State())

    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        state.withLock { $0.handle(argv) }
    }

    /// Stdin is recorded as a trailing `<stdin>`, text pair so tests can still
    /// inspect the script an exec delivered.
    func run(_ argv: [String], input: Data, cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        state.withLock { $0.handle(argv + ["<stdin>", String(decoding: input, as: UTF8.self)]) }
    }

    func argvSnapshot() -> [[String]] {
        state.withLock { $0.argvs }
    }

    /// The local images `image list` prints from now on.
    func setImages(_ images: [String]) {
        state.withLock { $0.images = images }
    }

    /// Makes `image list` fail, like a CLI whose system service is down.
    func failImageList() {
        state.withLock { $0.imageListFails = true }
    }

    /// From now on, an `exec` whose stdin script contains `needle` prints `stdout`, as the real CLI relays what the
    /// script printed.
    func answerExec(containing needle: String, stdout: String) {
        state.withLock { $0.execAnswers.append((needle, stdout)) }
    }
}
