import Foundation

public protocol SSHExecuting: Sendable {
    func exec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws -> ShellResult
}

/// Executes scripts inside runner VMs over SSH. Tart images ship with the
/// `admin` user and our key installed during `kinhin image prepare`.
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
        var argv = [
            "ssh",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "BatchMode=yes",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=10",
        ]
        // Cirrus Labs images trust the key Tart generates at ~/.tart/ssh.
        if let tartKey = Self.tartHostKey() {
            argv += ["-i", tartKey]
        }
        // The script (it carries registration tokens) goes over stdin, not the
        // command line, so it never shows up in the host's process list.
        argv += ["\(user)@\(ip)", "bash -s"]
        return try await shell.run(argv, input: Data(script.utf8), cwd: nil, timeout: timeout)
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
