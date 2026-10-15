import Foundation

/// One isolated kinhin install: its own support directory (config, state, logs, daemon socket) and its own tokens,
/// so a run never reads or writes the developer's real setup. Tokens travel as `KINHIN_TOKEN_<NAME>` environment
/// variables (a debug-build feature), so the Keychain is never involved.
public final class Sandbox: @unchecked Sendable {
    public let id: String
    /// Short on purpose: the daemon socket lives inside, and a unix socket path is capped near 100 bytes.
    public let supportDirectory: URL
    private let lock = NSLock()
    private var tokens: [String: String] = [:]
    /// Extra variables for every kinhin this sandbox runs (debug-build switches such as `KINHIN_HEALING_TIMINGS`).
    private var overrides: [String: String] = [:]
    /// Every daemon this sandbox started, so `dispose()` can stop the ones a test forgot (or stopped too late).
    private var daemons: [Daemon] = []

    public var configURL: URL { supportDirectory.appendingPathComponent("config.yaml") }
    public var logURL: URL { supportDirectory.appendingPathComponent("logs/kinhin.log") }
    public var socketURL: URL { supportDirectory.appendingPathComponent("daemon.sock") }

    public init() throws {
        id = E2E.randomID()
        supportDirectory = URL(fileURLWithPath: "/tmp/ke2e-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.isExecutableFile(atPath: E2E.kinhinBinary) else {
            throw E2EError.unavailable("no kinhin binary at \(E2E.kinhinBinary); run scripts/e2e.sh (it builds one)")
        }
    }

    /// Registers the token the account named `account` will read.
    public func setToken(_ token: String, account: String) {
        lock.withLock { tokens[account] = token }
    }

    /// Sets `value` (nil removes it) for every kinhin run in this sandbox from now on, the daemon included.
    public func setEnvironment(_ key: String, _ value: String?) {
        lock.withLock { overrides[key] = value }
    }

    public var environment: [String: String] {
        var env = Shell.baseEnvironment()
        env["KINHIN_SUPPORT_DIR"] = supportDirectory.path
        env["KINHIN_TOKEN_STORE"] = "env"
        // Mint and adopt only `ke2e-*` instances, so a real fleet on this Mac is never touched (see `Instances.ownPrefix`).
        env["KINHIN_INSTANCE_PREFIX"] = Instances.ownPrefix
        // Never inherit a developer's real forge tokens, nor healing switches meant for one scenario.
        for key in env.keys
        where (key.hasPrefix("KINHIN_TOKEN_") && key != "KINHIN_TOKEN_STORE") || key.hasPrefix("KINHIN_HEALING_") {
            env[key] = nil
        }
        for (account, token) in lock.withLock({ tokens }) {
            env[Sandbox.tokenVariable(for: account)] = token
        }
        for (key, value) in lock.withLock({ overrides }) { env[key] = value }
        return env
    }

    /// Mirrors `KeychainTokenStore.environmentVariableName(for:)`: upper-cased, non-alphanumerics become `_`.
    public static func tokenVariable(for account: String) -> String {
        "KINHIN_TOKEN_" + String(account.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
    }

    public func writeConfig(_ yaml: String) throws {
        try Data(yaml.utf8).write(to: configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    /// Runs the CLI in this sandbox.
    @discardableResult
    public func kinhin(
        _ arguments: [String], stdin: String? = nil, timeout: TimeInterval = 120
    ) async throws -> ProcessResult {
        try await Shell.run(
            E2E.kinhinBinary, arguments, environment: environment, stdin: stdin, timeout: timeout)
    }

    /// Everything kinhin logged in this sandbox.
    public func log() -> String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }

    /// Starts `kinhin daemon` (the production headless path: engine plus RPC socket) and waits until it answers.
    public func startDaemon() async throws -> Daemon {
        let daemon = Daemon(sandbox: self)
        try daemon.launch()
        lock.withLock { daemons.append(daemon) }
        try await eventually("the daemon to answer on its socket", timeout: 60, interval: 1) {
            let result = try await self.kinhin(["status", "--json"], timeout: 15)
            return result.ok ? true : nil
        }
        return daemon
    }

    public func dispose() {
        // A daemon that outlives its sandbox is an orphan: its directory is gone, so the sweep script can no longer find it.
        for daemon in lock.withLock({ daemons }) { daemon.kill() }
        try? FileManager.default.removeItem(at: supportDirectory)
    }
}

/// A running `kinhin daemon` child process.
public final class Daemon: @unchecked Sendable {
    private let sandbox: Sandbox
    private var process: Process?

    init(sandbox: Sandbox) { self.sandbox = sandbox }

    public var processID: Int32? { process?.processIdentifier }
    public var isRunning: Bool { process?.isRunning ?? false }

    func launch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: E2E.kinhinBinary)
        process.arguments = ["daemon"]
        process.environment = sandbox.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        // Lets scripts/e2e.sh find and stop this daemon if the test process is killed before it can tear down.
        try? Data("\(process.processIdentifier)\n".utf8).write(
            to: sandbox.supportDirectory.appendingPathComponent("daemon.pid"))
    }

    /// SIGKILL: no cleanup runs, the way a crash or power loss leaves things.
    public func kill() {
        guard let process, process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }

    /// A graceful stop through the CLI, then the process itself if it lingers.
    public func stop() async {
        guard let process, process.isRunning else { return }
        _ = try? await sandbox.kinhin(["stop"], timeout: 60)
        for _ in 0..<30 where process.isRunning { try? await Task.sleep(for: .seconds(1)) }
        // A daemon that ignores SIGTERM must not hang the run (a bare waitUntilExit() did): bounded wait, then SIGKILL.
        if process.isRunning {
            process.terminate()
            for _ in 0..<10 where process.isRunning { try? await Task.sleep(for: .seconds(1)) }
        }
        if process.isRunning { kill() }
    }
}
