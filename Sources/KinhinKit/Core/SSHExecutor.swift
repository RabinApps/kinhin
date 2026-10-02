import Foundation

public protocol SSHExecuting: Sendable {
    func exec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws -> ShellResult
    func allowKeys(_ key: String) async throws
}

/// Executes scripts inside runner VMs over SSH. Tart images ship with the
/// `admin` user; `kinhin image prepare` installs our key (see `GuestSSHKey`).
public struct SSHExecutor: SSHExecuting {
    let shell: ShellRunning
    let user: String

    public init(shell: ShellRunning = Shell(), user: String = "admin") {
        self.shell = shell
        self.user = user
    }

    public func exec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws
        -> ShellResult
    {
        // The user is spliced into "user@ip"; a leading dash or odd character would
        // let a config value become an ssh option.
        guard Self.isSafeUser(user) else {
            throw TartError.commandFailed(what: "ssh to \(vm)", stderr: "refusing unsafe ssh user '\(user)'")
        }
        var argv = [
            Self.sshPath,
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
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
