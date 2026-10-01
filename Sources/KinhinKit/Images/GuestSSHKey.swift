import Foundation

/// The SSH key kinhin uses to reach runner VMs. Cirrus Labs base images trust no
/// key and `SSHExecutor` never sends a password (`BatchMode`), so `image prepare`
/// installs this key through `tart exec` (the guest agent) before its first SSH
/// call. Runner VMs are clones of the prepared image and inherit it.
enum GuestSSHKey {
    /// Where `SSHExecutor.tartHostKey()` looks for the private key.
    static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.tart/ssh", isDirectory: true)
    }

    static let keygenPath = "/usr/bin/ssh-keygen"

    /// The public half of the key SSH will offer, creating an ed25519 keypair when
    /// the directory has none. An existing key (ed25519 first, then rsa, the order
    /// `SSHExecutor` uses) is reused and never overwritten.
    static func publicKey(in directory: URL = defaultDirectory, shell: ShellRunning = Shell()) async throws -> String {
        let fm = FileManager.default
        for name in ["id_ed25519", "id_rsa"] {
            let priv = directory.appendingPathComponent(name)
            guard fm.fileExists(atPath: priv.path) else { continue }
            let pub = directory.appendingPathComponent(name + ".pub")
            if fm.fileExists(atPath: pub.path) { return try validated(String(contentsOf: pub, encoding: .utf8)) }
            let derived = try await shell.run([keygenPath, "-y", "-f", priv.path], cwd: nil, timeout: 30)
            guard derived.succeeded else {
                throw ImageError.provisioningFailed(
                    "could not read the public key for \(priv.path): \(derived.failureExcerpt)")
            }
            return try validated(derived.stdout)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let priv = directory.appendingPathComponent("id_ed25519")
        let made = try await shell.run(
            [keygenPath, "-q", "-t", "ed25519", "-N", "", "-C", "kinhin-guest", "-f", priv.path], cwd: nil, timeout: 30)
        guard made.succeeded else {
            throw ImageError.provisioningFailed(
                "could not create an SSH key in \(directory.path): \(made.failureExcerpt)")
        }
        Log.info("image", "created the guest SSH key \(priv.path)")
        return try validated(String(contentsOf: directory.appendingPathComponent("id_ed25519.pub"), encoding: .utf8))
    }

    /// One `type base64 [comment]` line and nothing else, so it is safe inside the
    /// single quotes of `installScript`.
    static func validated(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            key.range(of: #"^ssh-(ed25519|rsa) [A-Za-z0-9+/=]+( [A-Za-z0-9._@-]+)?$"#, options: .regularExpression)
                != nil
        else {
            throw ImageError.provisioningFailed("the guest SSH public key is not a single ssh-ed25519/ssh-rsa line")
        }
        return key
    }

    /// Idempotent: appends `publicKey` to the guest user's authorized_keys once.
    /// `user` and `publicKey` must already be validated (`SSHExecutor.isSafeUser`, `validated`).
    static func installScript(publicKey: String, user: String) -> String {
        """
        set -e; d="$(eval echo ~\(user))/.ssh"; mkdir -p "$d"; chmod 700 "$d"; touch "$d/authorized_keys"; \
        grep -qxF '\(publicKey)' "$d/authorized_keys" || echo '\(publicKey)' >> "$d/authorized_keys"; \
        chmod 600 "$d/authorized_keys"
        """
    }
}
