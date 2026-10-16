import Foundation
import Synchronization

/// A booted guest the suites run scripts in: a Tart VM, a container, or the
/// host's scratch work directory.
struct BenchmarkInstance: Sendable {
    let runtimeID: RuntimeID
    let runtime: any Runtime
    let name: String
    /// The address the runtime's transport dials (Tart); nil for exec transports.
    let ip: String?
    let platform: ToolchainPlatform
    /// Shell assignment of `BENCH`, the guest scratch directory every script `cd`s into.
    let benchDirectory: String
    /// Run scripts through `BenchmarkScripts.isolatingStdin` (always, outside tests that read raw scripts).
    var isolatesStdin = true

    var platformLabel: String { platform == .macOS ? "macOS" : "linux" }

    func exec(_ script: String, timeout: TimeInterval) async throws -> ShellResult {
        try await runtime.execRegistration(
            name, ip: ip, isolatesStdin ? BenchmarkScripts.isolatingStdin(script) : script, timeout: timeout)
    }

    /// The preamble every generated script starts with: strict mode, the tool
    /// PATH an SSH shell lacks, and the scratch directory.
    var prelude: String {
        BenchmarkScripts.prelude(platform: platform, benchDirectory: benchDirectory)
    }
}

/// Every instance a run creates, recorded before its provisioning starts so a
/// failed or cancelled run still removes it. Teardown is idempotent.
final class InstanceTracker: Sendable {
    private struct Entry: Sendable {
        let name: String
        let runtime: any Runtime
    }

    private let entries = Mutex<[Entry]>([])
    private let counter = Mutex(0)

    func nextIndex() -> Int {
        counter.withLock { value in
            value += 1
            return value
        }
    }

    func track(name: String, runtime: any Runtime) {
        entries.withLock { $0.append(Entry(name: name, runtime: runtime)) }
    }

    /// Tears one tracked instance down now (a finished boot iteration).
    func release(name: String) async {
        // Take the instance out of the tracked list (nil when it was already released).
        let entry = entries.withLock { entries -> Entry? in
            guard let index = entries.firstIndex(where: { $0.name == name }) else { return nil }
            return entries.remove(at: index)
        }
        guard let entry else { return }
        await Self.teardown(entry)
    }

    /// Tears down everything still tracked, newest first. Never throws.
    func releaseAll() async {
        let remaining = entries.withLock { entries -> [Entry] in
            defer { entries.removeAll() }
            return entries.reversed()
        }
        for entry in remaining { await Self.teardown(entry) }
    }

    var trackedNames: [String] { entries.withLock { $0.map(\.name) } }

    private static func teardown(_ entry: Entry) async {
        // Cancellation must not skip the cleanup it triggered.
        await bestEffortAsync(entry.name, "removing benchmark instance") {
            try await withoutCancellation { try await entry.runtime.teardown(id: entry.name) }
        }
    }
}
