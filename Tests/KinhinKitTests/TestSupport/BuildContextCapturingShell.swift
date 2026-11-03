import Foundation
import Synchronization

@testable import KinhinKit
@testable import KinhinTestSupport

/// Forwards to a `FakeShell`, and snapshots the build context of each
/// `container build` call before the preparer deletes it.
final class BuildContextCapturingShell: ShellRunning, Sendable {
    struct Context: Sendable {
        let argv: [String]
        let dockerfile: String
        /// Script files of the context's `bake/` directory by name.
        let scripts: [String: String]
    }

    let inner = FakeShell()
    private let captured = Mutex<[Context]>([])

    var builds: [Context] { captured.withLock { $0 } }

    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        if argv.dropFirst().first == "build", let path = argv.last {
            let dir = URL(fileURLWithPath: path)
            let names =
                (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("bake").path)) ?? []
            var scripts: [String: String] = [:]
            for name in names {
                scripts[name] = try? String(contentsOf: dir.appendingPathComponent("bake/\(name)"), encoding: .utf8)
            }
            let dockerfile = (try? String(contentsOf: dir.appendingPathComponent("Dockerfile"), encoding: .utf8)) ?? ""
            captured.withLock { $0.append(Context(argv: argv, dockerfile: dockerfile, scripts: scripts)) }
        }
        return try await inner.run(argv, cwd: cwd, timeout: timeout)
    }
}
