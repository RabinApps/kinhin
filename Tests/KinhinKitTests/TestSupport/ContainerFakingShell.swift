import Foundation
import Synchronization

@testable import KinhinKit

/// A shell double that models `container list` as real state: `run --name X`
/// creates container X, `delete --force X` removes it, and list returns the
/// current names — so provision/awaitRunning/provision-after-recovery behave
/// like the real CLI. `image list` prints the images `setImages` stored (one
/// per line, like `container image list --quiet`), or fails after
/// `failImageList()`. Other argvs return success. Matches the binary on any
/// install prefix so the test stays independent of the host PATH.
final class ContainerFakingShell: ShellRunning, Sendable {
    private struct State: Sendable {
        var argvs: [[String]] = []
        var containers: Set<String> = []
        var images: [String] = []
        var imageListFails = false

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
                    containers.insert(argv[nameIdx + 1])
                }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
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
}
