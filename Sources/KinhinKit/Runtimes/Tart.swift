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
                "tart not found at '\(path)'. Install it with: \(TartHealthProbe.installCommand)"
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
    /// (`--dir name:hostpath` specs; macOS guests auto-mount under "/Volumes/My Shared Files").
    func run(name: String, mounts: [String]) async throws
    /// Convenience for callers that never mount host directories.
    func run(name: String) async throws
    func ip(of name: String, timeout: TimeInterval) async throws -> String
    func sshExec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws
        -> ShellResult
    func stop(name: String) async throws
    func delete(name: String) async throws
    func pull(image: String) async throws
    /// Trusts kinhin's guest SSH key for `user` in the booted VM, through the
    /// guest agent (`tart exec`), so the first SSH call can authenticate. The
    /// default does nothing (fakes, stand-ins).
    func installGuestSSHKey(vm: String, user: String) async throws
    /// Creates an empty Linux VM (`tart create --linux name`) with no OS —
    /// the starting point of the "Linux VM from scratch" flow.
    func createLinux(name: String) async throws
    /// Boots the VM with `isoPath` attached as a second disk
    /// (`tart run --disk <iso>`), for one-time OS installs.
    func runWithDisk(name: String, isoPath: String) async throws
}

public extension TartControlling {
    func run(name: String) async throws {
        try await run(name: name, mounts: [])
    }

    func installGuestSSHKey(vm: String, user: String) async throws {}
}

/// Real implementation that shells out to the tart binary.
public struct TartController: TartControlling {
    let binary: String
    let shell: ShellRunning
    /// Boot VMs with `--net-softnet` (isolated from each other and the LAN).
    let softnet: Bool
    /// Where the guest SSH key lives; overridden by tests.
    var guestKeyDirectory = GuestSSHKey.defaultDirectory

    public init(configuredPath: String? = nil, shell: ShellRunning = Shell(), softnet: Bool = false) throws {
        guard let found = Paths.findExecutable(named: "tart", override: configuredPath) else {
            throw TartError.missingBinary(path: configuredPath ?? "PATH")
        }
        self.binary = found
        self.shell = shell
        self.softnet = softnet
    }

    /// The `tart run` argument list; separate from `run` so it can be tested
    /// without launching a VM.
    static func runArguments(name: String, mounts: [String], softnet: Bool) -> [String] {
        // `--dir name:hostpath` shares: macOS guests auto-mount them under
        // "/Volumes/My Shared Files/<name>" (tart's documented directory-sharing flag).
        let mountArgs = mounts.flatMap { ["--dir", $0] }
        return ["run", "--no-graphics"] + (softnet ? ["--net-softnet"] : []) + mountArgs + [name]
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
        process.arguments = Self.runArguments(name: name, mounts: mounts, softnet: softnet)
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
        // The script goes over stdin so it never appears in the process list.
        let argv = [
            SSHExecutor.sshPath,
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=10",
            "\(user)@\(ip)",
            "bash -s",
        ]
        let res = try await shell.run(argv, input: Data(script.utf8), cwd: nil, timeout: timeout)
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

    public func installGuestSSHKey(vm: String, user: String) async throws {
        guard SSHExecutor.isSafeUser(user) else {
            throw TartError.commandFailed(what: "exec \(vm)", stderr: "refusing unsafe ssh user '\(user)'")
        }
        let key = try await GuestSSHKey.publicKey(in: guestKeyDirectory, shell: shell)
        let script = GuestSSHKey.installScript(publicKey: key, user: user)
        let res = try await exec(["exec", vm, "bash", "-c", script], timeout: 60)
        guard res.succeeded else { throw TartError.commandFailed(what: "exec \(vm)", stderr: res.failureExcerpt) }
    }

    public func createLinux(name: String) async throws {
        let res = try await exec(["create", "--linux", name])
        guard res.succeeded else {
            throw TartError.commandFailed(what: "create --linux \(name)", stderr: res.stderr)
        }
    }

    public func runWithDisk(name: String, isoPath: String) async throws {
        // `tart run` blocks while the VM runs; launch it detached like `run`.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["run", "--no-graphics", "--disk", isoPath, name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw TartError.commandFailed(what: "run --disk \(name)", stderr: error.localizedDescription)
        }
    }
}

/// Stand-in used when tart is not installed but the fleet runs Linux jobs on
/// Docker or Apple container. Every call fails clearly; nothing routes macOS
/// work to it because the engine's primary runtime is the Linux one.
struct UnavailableTart: TartControlling {
    init() {}
    private var missing: TartError { .missingBinary(path: "PATH") }
    func list() async throws -> [TartVM] { [] }
    func clone(source: String, to name: String) async throws { throw missing }
    func run(name: String, mounts: [String]) async throws { throw missing }
    func ip(of name: String, timeout: TimeInterval) async throws -> String { throw missing }
    func sshExec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws
        -> ShellResult
    { throw missing }
    func stop(name: String) async throws { throw missing }
    func delete(name: String) async throws { throw missing }
    func pull(image: String) async throws { throw missing }
    func createLinux(name: String) async throws { throw missing }
    func runWithDisk(name: String, isoPath: String) async throws { throw missing }
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
            let softnet = tartSoftnet == true
            // Fail at start-up rather than at the first job: with isolation
            // requested, booting without softnet would silently run VMs on the
            // shared network.
            if softnet, Paths.findExecutable(named: "softnet", override: nil) == nil {
                throw TartError.missingBinary(path: "softnet (tart_softnet: true; brew install openai/tools/softnet)")
            }
            return try TartController(configuredPath: tartPath, softnet: softnet)
        }
        if hasLinuxRuntime { return UnavailableTart() }
        throw TartError.missingBinary(path: tartPath ?? "PATH")
    }
}
