import Foundation
import Synchronization

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
    func stop(name: String) async throws
    func delete(name: String) async throws
    func pull(image: String) async throws
    /// Trusts kinhin's guest SSH key for `user` in the booted VM, through the
    /// guest agent (`tart exec`), so the first SSH call can authenticate. The
    /// default does nothing (fakes, stand-ins).
    func installGuestSSHKey(vm: String, user: String) async throws
    /// Turns off SSH password / keyboard-interactive login in the booted VM
    /// through the guest agent (`tart exec`), so the curated images' default
    /// password is never usable over the network. The default does nothing.
    func hardenGuestSSH(vm: String) async throws
    /// Replaces the booted VM's sshd host keys with freshly generated ones
    /// through the guest agent and returns the new ed25519 public key
    /// (`ssh-ed25519 AAAA...`). Every runner VM is a clone of one image, so
    /// without this they all share one host key; the agent channel is host-VM
    /// only, so the returned key cannot be spoofed on the network. nil means
    /// this controller cannot do it (fakes, stand-ins).
    func rotateGuestHostKey(vm: String) async throws -> String?
    /// Creates an empty Linux VM (`tart create --linux name`) with no OS —
    /// the starting point of the "Linux VM from scratch" flow.
    func createLinux(name: String) async throws
    /// Boots the VM with `isoPath` attached as a second disk
    /// (`tart run --disk <iso>`), for one-time OS installs.
    func runWithDisk(name: String, isoPath: String) async throws
    /// Host-side resource use of each named VM's `tart run` process: resident
    /// memory and cumulative CPU time. Names with no live process are absent.
    /// The default reports nothing (fakes, stand-ins).
    func processSamples(of names: [String]) async throws -> [String: ProcessSample]
    /// Memory the guest itself is using (MB), read over the guest agent. The
    /// host process maps the whole guest RAM, so its RSS cannot show this.
    /// Nil when the guest cannot answer. The default reports nothing.
    func guestMemoryUsedMB(of name: String) async -> Int?
}

public extension TartControlling {
    func run(name: String) async throws {
        try await run(name: name, mounts: [])
    }

    func installGuestSSHKey(vm: String, user: String) async throws {}
    func hardenGuestSSH(vm: String) async throws {}
    func rotateGuestHostKey(vm: String) async throws -> String? { nil }
    func processSamples(of names: [String]) async throws -> [String: ProcessSample] { [:] }
    func guestMemoryUsedMB(of name: String) async -> Int? { nil }
}

/// Real implementation that shells out to the tart binary.
public struct TartController: TartControlling {
    let binary: String
    let shell: ShellRunning
    /// Boot VMs with `--net-softnet` (isolated from each other and the LAN).
    let softnet: Bool
    /// Where the guest SSH key lives; overridden by tests.
    var guestKeyDirectory = GuestSSHKey.defaultDirectory

    /// - Parameters:
    ///   - configuredPath: The tart binary to run — almost always the
    ///   config's `tart_path:`, so the controller and every health probe
    ///   answer for the same binary the fleet runs. Explicit `nil` only
    ///   when no config was read (PATH is then the honest answer). Never
    ///   defaulted: a bare init would silently search PATH.
    ///   - shell: How to launch tart (tests inject fakes).
    ///   - softnet: Boot VMs with `--net-softnet`.
    public init(configuredPath: String?, shell: ShellRunning = Shell(), softnet: Bool = false) throws {
        guard let found = Paths.findExecutable(named: "tart", override: configuredPath) else {
            throw TartError.missingBinary(path: configuredPath ?? "PATH")
        }
        self.binary = found
        self.shell = shell
        self.softnet = softnet
    }

    /// A bare controller cannot be constructed — see the designated init.
    @available(
        *, unavailable, message: "pass configuredPath: the config's tart_path (nil only when no config was read)"
    )
    public init(shell: ShellRunning = Shell(), softnet: Bool = false) throws {
        try self.init(configuredPath: nil, shell: shell, softnet: softnet)
    }

    /// The `tart run` argument list; separate from `run` so it can be tested
    /// without launching a VM.
    static func runArguments(name: String, mounts: [String], softnet: Bool) -> [String] {
        // `--dir name:hostpath` shares: macOS guests auto-mount them under
        // "/Volumes/My Shared Files/<name>" (tart's documented directory-sharing flag).
        let mountArgs = mounts.flatMap { ["--dir", $0] }
        return ["run", "--no-graphics"] + (softnet ? ["--net-softnet"] : []) + mountArgs + [name]
    }

    /// `tart run --net-softnet` looks `softnet` up on PATH, and a GUI-launched
    /// app has only /usr/bin:/bin:..., so without Homebrew's bin directories the
    /// VM never boots ("softnet not found in PATH") and no IP ever appears.
    static func runEnvironment(base: [String: String], softnet: Bool) -> [String: String] {
        guard softnet else { return base }
        var env = base
        var dirs = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        var extra = ["/opt/homebrew/bin", "/usr/local/bin"]
        if let found = Paths.findExecutable(named: "softnet") {
            extra.insert((found as NSString).deletingLastPathComponent, at: 0)
        }
        for dir in extra where !dirs.contains(dir) { dirs.append(dir) }
        env["PATH"] = dirs.joined(separator: ":")
        return env
    }

    /// - Parameter configuredPath: The config's `tart_path:`; explicit
    ///   `nil` only to check PATH deliberately (an environment gate with no
    ///   config in scope). Never defaulted: a bare check would silently
    ///   answer for a binary the fleet may not run.
    public static func isInstalled(configuredPath: String?) -> Bool {
        Paths.findExecutable(named: "tart", override: configuredPath) != nil
    }

    /// A bare check cannot be constructed — see `isInstalled(configuredPath:)`.
    @available(*, unavailable, message: "pass configuredPath: the config's tart_path (nil to check PATH deliberately)")
    public static func isInstalled() -> Bool {
        isInstalled(configuredPath: nil)
    }

    func exec(_ args: [String], timeout: TimeInterval = 120) async throws -> ShellResult {
        try await shell.run([binary] + args, cwd: nil, timeout: timeout)
    }

    public func list() async throws -> [TartVM] {
        // Newer tart builds print only names for `--quiet`, so ask for JSON.
        let json = try await exec(["list", "--format", "json"])
        var jsonError: Error?
        if json.succeeded {
            do { return try Self.parseListJSON(json.stdout) } catch { jsonError = error }
        }
        let res = try await exec(["list", "--quiet"])
        guard res.succeeded else { throw TartError.commandFailed(what: "list", stderr: res.stderr) }
        let vms = Self.parseList(res.stdout)
        // Newer tart prints bare names for `--quiet`, which parse to nothing:
        // an empty result from non-empty output is unreadable, not "no VMs".
        if vms.isEmpty, !res.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let why = jsonError.map { ": \($0.localizedDescription)" } ?? ""
            throw TartError.commandFailed(what: "list", stderr: "could not read the output\(why)")
        }
        return vms
    }

    /// Parse `tart list --format json`; throws when the output isn't that JSON.
    static func parseListJSON(_ text: String) throws -> [TartVM] {
        struct Entry: Decodable {
            let Name: String
            let Source: String
            let State: String
            let Disk: Int?
        }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(text.utf8))
        return entries.map { TartVM(name: $0.Name, source: $0.Source, status: $0.State, diskGB: $0.Disk) }
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
        process.environment = Self.runEnvironment(base: ProcessInfo.processInfo.environment, softnet: softnet)
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // stderr is drained into a short tail so an exit can be explained
        // (a boot failure otherwise surfaces only as an IP timeout minutes later).
        let errors = Pipe()
        let tail = Mutex(Data())
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            tail.withLock { data in
                data.append(chunk)
                if data.count > Self.runTailBytes { data = data.suffix(Self.runTailBytes) }
            }
        }
        process.standardError = errors
        process.terminationHandler = { finished in
            let text = tail.withLock { String(decoding: $0, as: UTF8.self) }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Self.logRunExit(
                vm: name, status: finished.terminationStatus, reason: finished.terminationReason, tail: text)
        }
        do {
            try process.run()
        } catch {
            errors.fileHandleForReading.readabilityHandler = nil
            throw TartError.commandFailed(what: "run \(name)", stderr: error.localizedDescription)
        }
        // Do not wait — the VM keeps running in its own process.
    }

    /// How much of `tart run`'s stderr an exit report keeps.
    static let runTailBytes = 2048

    /// Reports that a VM's `tart run` process ended. A clean exit is the
    /// normal end of a VM (`tart stop`); anything else is a crash, so the
    /// reason and stderr tail are logged where the VM's log lines are.
    static func logRunExit(vm: String, status: Int32, reason: Process.TerminationReason, tail: String) {
        if status == 0, reason == .exit {
            Log.info(vm, "tart run exited")
        } else {
            let how = reason == .uncaughtSignal ? "killed by signal \(status)" : "exited with status \(status)"
            Log.warn(vm, "tart run \(how)" + (tail.isEmpty ? "" : ": \(tail)"))
        }
    }

    public func ip(of name: String, timeout: TimeInterval = 120) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error = TartError.ipNotFound(vm: name)
        while Date() < deadline {
            let attemptStart = ContinuousClock.now
            let res = try await exec(["ip", "--wait", "5", name], timeout: 30)
            if res.succeeded {
                let candidate = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.isValidIPv4(candidate) { return candidate }
            }
            lastError = TartError.ipNotFound(vm: name)
            // `--wait 5` already blocked for its own timeout; only a command
            // that failed instantly (VM not up yet) needs a pause to avoid a spin.
            if ContinuousClock.now - attemptStart < .seconds(1) { try await Task.sleep(for: .milliseconds(500)) }
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

    public func hardenGuestSSH(vm: String) async throws {
        let res = try await exec(["exec", vm, "bash", "-c", RunnerBootstrap.sshHardeningScript()], timeout: 120)
        guard res.succeeded else { throw TartError.commandFailed(what: "exec \(vm)", stderr: res.failureExcerpt) }
    }

    public func rotateGuestHostKey(vm: String) async throws -> String? {
        let res = try await exec(["exec", vm, "bash", "-c", GuestHostKeyPinning.rotateScript], timeout: 120)
        guard res.succeeded else { throw TartError.commandFailed(what: "exec \(vm)", stderr: res.failureExcerpt) }
        guard let key = GuestHostKeyPinning.parseHostKey(res.stdout) else {
            throw TartError.commandFailed(what: "exec \(vm)", stderr: "the guest returned no ssh-ed25519 host key")
        }
        return key
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
