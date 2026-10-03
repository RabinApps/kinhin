import Foundation

public protocol SSHExecuting: Sendable {
    func exec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws -> ShellResult
    func allowKeys(_ key: String) async throws
    /// A cheap check that the guest's sshd accepts connections, so callers
    /// poll this instead of spawning `ssh` per attempt. Executors with no
    /// network transport (fakes) report true.
    func isSSHPortOpen(ip: String) async -> Bool
    /// Pins the guest's ssh-ed25519 host key (`ssh-ed25519 AAAA...`) for `vm`,
    /// learned over the guest-agent channel, so later `exec` calls verify it.
    /// Executors with no network transport (fakes) ignore it.
    func pinHostKey(vm: String, publicKey: String) async throws
    /// Drops what `pinHostKey` stored for `vm` (VM teardown).
    func forgetHostKey(vm: String) async
    /// The host key of `vm` could not be learned; connections to it stay unverified.
    func noteHostKeyUnpinned(vm: String, reason: String) async
}

extension SSHExecuting {
    public func isSSHPortOpen(ip: String) async -> Bool { true }
    public func pinHostKey(vm: String, publicKey: String) async throws {}
    public func forgetHostKey(vm: String) async {}
    public func noteHostKeyUnpinned(vm: String, reason: String) async {}
}

/// Executes scripts inside runner VMs over SSH. Tart images ship with the
/// `admin` user; `kinhin image prepare` installs our key (see `GuestSSHKey`).
public struct SSHExecutor: SSHExecuting {
    public func isSSHPortOpen(ip: String) async -> Bool {
        await TCPProbe.isOpen(host: ip, port: 22)
    }

    let shell: ShellRunning
    let user: String
    private let pins: GuestHostKeyPins

    /// `knownHostsDirectory` holds the per-instance known-hosts files (default:
    /// a private temp directory made on first use); `fallbackMarker` is where
    /// an unverified connection is recorded for `kinhin doctor`.
    public init(shell: ShellRunning = Shell(), user: String = "admin") {
        self.init(shell: shell, user: user, knownHostsDirectory: nil, fallbackMarker: GuestHostKeyPinning.markerURL)
    }

    init(shell: ShellRunning, user: String, knownHostsDirectory: URL?, fallbackMarker: URL) {
        self.shell = shell
        self.user = user
        self.pins = GuestHostKeyPins(directory: knownHostsDirectory, marker: fallbackMarker)
    }

    public func pinHostKey(vm: String, publicKey: String) async throws {
        try pins.pin(vm: vm, publicKey: publicKey)
    }

    public func forgetHostKey(vm: String) async { pins.forget(vm: vm) }

    public func noteHostKeyUnpinned(vm: String, reason: String) async {
        pins.noteUnpinned(vm: vm, reason: reason)
    }

    public func exec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws
        -> ShellResult
    {
        // The user is spliced into "user@ip"; a leading dash or odd character would
        // let a config value become an ssh option.
        guard Self.isSafeUser(user) else {
            throw TartError.commandFailed(what: "ssh to \(vm)", stderr: "refusing unsafe ssh user '\(user)'")
        }
        var argv =
            [Self.sshPath] + pins.hostKeyOptions(vm: vm) + [
                "-o", "BatchMode=yes",
                "-o", "LogLevel=ERROR",
                "-o", "ConnectTimeout=10",
            ]
        // kinhin's own guest key (~/.tart/ssh): `image prepare` trusts it in the VM via `tart exec`.
        if let tartKey = Self.tartHostKey() {
            argv += ["-i", tartKey]
        }
        // The script (it carries registration tokens) goes over stdin, not the
        // command line, so it never shows up in the host's process list.
        argv += ["\(user)@\(ip)", "bash -s"]
        return try await shell.run(argv, input: Data(script.utf8), cwd: nil, timeout: timeout)
    }

    public func allowKeys(_ key: String) async throws {
        // No-op: the host key kinhin already trusts in the VM is the one that
        // matters; an additional allowlist entry is not required.
    }

    /// Absolute, so a file named `ssh` in the working directory is never run.
    static let sshPath = "/usr/bin/ssh"

    static func isSafeUser(_ user: String) -> Bool {
        user.range(of: #"^[A-Za-z_][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
    }

    static func tartHostKey() -> String? {
        let base = NSHomeDirectory() + "/.tart/ssh"
        for name in ["id_ed25519", "id_rsa"] {
            let candidate = "\(base)/\(name)"
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
