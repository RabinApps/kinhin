import Foundation

public struct TartVM: Sendable, Equatable {
    public let name: String
    public let source: String
    public let status: String  // "running" | "suspended" | "stopped" | ...
    public let cpu: Int?
    let memoryMB: Int?
    public let diskGB: Int?

    public init(name: String, source: String, status: String, cpu: Int? = nil, memoryMB: Int? = nil, diskGB: Int? = nil)
    {
        self.name = name
        self.source = source
        self.status = status
        self.cpu = cpu
        self.memoryMB = memoryMB
        self.diskGB = diskGB
    }
}

public enum TartError: LocalizedError {
    case missingBinary(path: String)
    case commandFailed(what: String, stderr: String)
    case ipNotFound(vm: String)

    public var errorDescription: String? {
        switch self {
        case .missingBinary(let path):
            return
                "tart not found at '\(path)'. Install it with: brew tap openai/tools && brew trust openai/tools && brew install openai/tools/tart"
        case .commandFailed(let what, let stderr):
            return "tart \(what) failed: \(stderr.prefix(400))"
        case .ipNotFound(let vm):
            return "could not resolve IP address for VM '\(vm)'"
        }
    }
}

public protocol TartControlling: Sendable {
    func list() async throws -> [TartVM]
    func clone(source: String, to name: String) async throws
    /// Boots the VM, optionally sharing host directories into the guest
    /// (tart virtiofs; macOS guests auto-mount under "/Volumes/My Shared Files").
    func run(name: String, mounts: [String]) async throws
    /// Convenience for callers that never mount host directories.
    func run(name: String) async throws
    func ip(of name: String, timeout: TimeInterval) async throws -> String
    func sshExec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws
        -> ShellResult
    func stop(name: String) async throws
    func delete(name: String) async throws
    func pull(image: String) async throws
}

public extension TartControlling {
    func run(name: String) async throws {
        try await run(name: name, mounts: [])
    }
}

/// Real implementation that shells out to the tart binary.
public struct TartController: TartControlling {
    let binary: String
    let shell: ShellRunning

    public init(configuredPath: String? = nil, shell: ShellRunning = Shell()) throws {
        guard let found = Paths.findExecutable(named: "tart", override: configuredPath) else {
            throw TartError.missingBinary(path: configuredPath ?? "PATH")
        }
        self.binary = found
        self.shell = shell
    }

    public static func isInstalled(configuredPath: String? = nil) -> Bool {
        Paths.findExecutable(named: "tart", override: configuredPath) != nil
    }

    func exec(_ args: [String], timeout: TimeInterval = 120) async throws -> ShellResult {
        try await shell.run([binary] + args, cwd: nil, timeout: timeout)
    }

    public func list() async throws -> [TartVM] {
        let res = try await exec(["list", "--quiet"])
        guard res.succeeded else { throw TartError.commandFailed(what: "list", stderr: res.stderr) }
        return Self.parseList(res.stdout)
    }

    /// Parse `tart list --quiet` output: lines of "name \t source \t status".
    static func parseList(_ text: String) -> [TartVM] {
        text.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { return nil }
            let mem =
                cols.count > 4
                ? Int(cols[4].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "GB", with: "")) : nil
            let cpu = cols.count > 3 ? Int(cols[3].trimmingCharacters(in: .whitespaces)) : nil
            return TartVM(
                name: String(cols[0]).trimmingCharacters(in: .whitespaces),
                source: String(cols[1]).trimmingCharacters(in: .whitespaces),
                status: String(cols[2]).trimmingCharacters(in: .whitespaces),
                cpu: cpu,
                memoryMB: mem.map { $0 * 1024 }
            )
        }
    }

    public func clone(source: String, to name: String) async throws {
        let res = try await exec(["clone", source, name], timeout: 300)
        guard res.succeeded else { throw TartError.commandFailed(what: "clone \(source) \(name)", stderr: res.stderr) }
    }

    public func run(name: String, mounts: [String]) async throws {
        // `tart run` blocks while the VM runs; launch it detached and return.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        // virtiofs shares: guests auto-mount under "/Volumes/My Shared Files".
        let mountArgs = mounts.flatMap { ["--virtiofs", $0] }
        process.arguments = ["run", "--no-graphics"] + mountArgs + [name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw TartError.commandFailed(what: "run \(name)", stderr: error.localizedDescription)
        }
        // Do not wait — the VM keeps running in its own process.
    }

    public func ip(of name: String, timeout: TimeInterval = 120) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error = TartError.ipNotFound(vm: name)
        while Date() < deadline {
            let res = try await exec(["ip", "--wait", "5", name], timeout: 30)
            if res.succeeded {
                let candidate = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.isValidIPv4(candidate) { return candidate }
            }
            lastError = TartError.ipNotFound(vm: name)
            try await Task.sleep(for: .seconds(2))
        }
        throw lastError
    }

    static func isValidIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            guard let v = UInt(p), v <= 255 else { return false }
            return String(p) == p  // no leading zeros / empty
        }
    }

    public func sshExec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws
        -> ShellResult
    {
        // Write the script to a temp file and pipe it over stdin-free SSH:
        // we base64 the script into the command line to avoid quoting issues.
        let b64 = Data(script.utf8).base64EncodedString()
        let remote = "echo \(b64) | base64 --decode | bash -s"
        let argv = [
            "ssh",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=10",
            "\(user)@\(ip)",
            remote,
        ]
        let res = try await shell.run(argv, cwd: nil, timeout: timeout)
        return res
    }

    public func stop(name: String) async throws {
        let res = try await exec(["stop", name], timeout: 120)
        // Already-stopped VMs are fine.
        guard res.succeeded || res.stderr.contains("not running") else {
            throw TartError.commandFailed(what: "stop \(name)", stderr: res.stderr)
        }
    }

    public func delete(name: String) async throws {
        let res = try await exec(["delete", name], timeout: 120)
        guard res.succeeded else { throw TartError.commandFailed(what: "delete \(name)", stderr: res.stderr) }
    }

    public func pull(image: String) async throws {
        let res = try await exec(["pull", image], timeout: 3600)
        guard res.succeeded else { throw TartError.commandFailed(what: "pull \(image)", stderr: res.stderr) }
    }
}

/// Stand-in used when tart is not installed but the fleet runs Linux jobs on
/// Docker or Apple container. Every call fails clearly; nothing routes macOS
/// work to it because the engine's primary runtime is the Linux one.
struct UnavailableTart: TartControlling {
    public init() {}
    private var missing: TartError { .missingBinary(path: "PATH") }
    public func list() async throws -> [TartVM] { [] }
    func clone(source: String, to name: String) async throws { throw missing }
    public func run(name: String, mounts: [String]) async throws { throw missing }
    public func ip(of name: String, timeout: TimeInterval) async throws -> String { throw missing }
    func sshExec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws
        -> ShellResult
    { throw missing }
    public func stop(name: String) async throws { throw missing }
    public func delete(name: String) async throws { throw missing }
    func pull(image: String) async throws { throw missing }
}

extension KinhinConfig {
    /// True when a Linux runtime (Apple container or Docker) is configured, so
    /// the fleet can run without tart (macOS jobs are then unavailable).
    var hasLinuxRuntime: Bool { container != nil || docker != nil }

    /// True when the fleet can start on this host: tart is installed, or a
    /// Linux runtime is configured to run instead.
    public func canRunOnThisHost() -> Bool {
        TartController.isInstalled(configuredPath: tartPath) || hasLinuxRuntime
    }

    /// The tart handle for an engine: the real controller when tart is
    /// installed, an inert stand-in for Linux-only fleets, else the usual
    /// "tart not found" error.
    public func makeTartControlling() throws -> TartControlling {
        if TartController.isInstalled(configuredPath: tartPath) {
            return try TartController(configuredPath: tartPath)
        }
        if hasLinuxRuntime { return UnavailableTart() }
        throw TartError.missingBinary(path: tartPath ?? "PATH")
    }
}
