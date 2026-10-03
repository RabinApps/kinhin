import Foundation
import Synchronization

/// Per-instance SSH host-key pinning for Tart guests.
///
/// Every runner VM is a clone of one image, so by default they all present the
/// same sshd host key, and on a shared virtual network a hostile VM could answer
/// on another VM's address and receive the registration script (runner tokens).
/// kinhin therefore regenerates the guest's host keys through the guest agent
/// (`tart exec`, a host-to-VM channel no other VM can reach), reads the new
/// public key back over the same channel, and has `SSHExecutor` verify it
/// strictly. When the guest agent cannot do this, connections fall back to the
/// old unverified behaviour, with a logged warning and a marker `kinhin doctor`
/// reports.
enum GuestHostKeyPinning {
    /// Runs in the guest through `tart exec`: new host keys, sshd restarted on
    /// Linux (macOS starts a fresh sshd per connection), new ed25519 key printed.
    static let rotateScript = """
        set -e
        sudo rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
        sudo ssh-keygen -A >/dev/null 2>&1
        sudo systemctl restart ssh >/dev/null 2>&1 || sudo systemctl restart sshd >/dev/null 2>&1 || true
        cat /etc/ssh/ssh_host_ed25519_key.pub
        """

    /// The `ssh-ed25519 <base64>` part of the guest's output, or nil when no
    /// well-formed key line is there. The trailing comment is dropped.
    static func parseHostKey(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, fields[0] == "ssh-ed25519" else { continue }
            let key = String(fields[1])
            if key.range(of: #"^[A-Za-z0-9+/]+={0,2}$"#, options: .regularExpression) != nil {
                return "ssh-ed25519 \(key)"
            }
        }
        return nil
    }

    /// Where an unverified connection is recorded so `kinhin doctor` (a separate
    /// process from the daemon) can warn about it.
    static var markerURL: URL { Paths.stateDirectory.appendingPathComponent("ssh-hostkey-unpinned") }

    /// The reason recorded by the last unverified connection, or nil when the
    /// last pin attempt succeeded (or none was ever recorded).
    static func recordedFallback(marker: URL = markerURL) -> String? {
        // A missing marker is not an error: nothing was ever unverified.
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        let reason = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? nil : reason
    }

    /// Rotates the guest's host key and pins it in `ssh`. Retries while the
    /// guest agent comes up (it starts after the VM has an IP). On failure or
    /// when `tart` cannot do it, tells `ssh` the VM stays unverified.
    static func pin(
        vm: String, tart: TartControlling, ssh: SSHExecuting, window: TimeInterval, interval: Duration
    ) async throws {
        let deadline = Date().addingTimeInterval(window)
        var reason = "the guest agent did not answer"
        while true {
            do {
                guard let key = try await tart.rotateGuestHostKey(vm: vm) else {
                    await ssh.noteHostKeyUnpinned(vm: vm, reason: "this tart controller cannot reach the guest agent")
                    return
                }
                try await ssh.pinHostKey(vm: vm, publicKey: key)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                reason = error.localizedDescription
            }
            if Date() >= deadline { break }
            try await Task.sleep(for: interval)
        }
        await ssh.noteHostKeyUnpinned(vm: vm, reason: reason)
    }
}

/// The known-hosts files `SSHExecutor` writes, one per instance, in a private
/// directory that is removed entry by entry at teardown.
final class GuestHostKeyPins: Sendable {
    private struct State {
        var files: [String: URL] = [:]
        var directory: URL?
        var warned = false
    }
    private let state = Mutex(State())
    private let marker: URL

    init(directory: URL?, marker: URL) {
        self.marker = marker
        state.withLock { $0.directory = directory }
    }

    /// ssh options for `vm`: strict checking against its pinned key when there
    /// is one, otherwise the previous unverified behaviour.
    func hostKeyOptions(vm: String) -> [String] {
        if let file = state.withLock({ $0.files[vm] }) {
            return [
                "-o", "StrictHostKeyChecking=yes",
                "-o", "HostKeyAlias=\(vm)",
                "-o", "UserKnownHostsFile=\(file.path)",
                "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", "HostKeyAlgorithms=ssh-ed25519",
                "-o", "UpdateHostKeys=no",
            ]
        }
        return ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null"]
    }

    func pin(vm: String, publicKey: String) throws {
        guard let key = GuestHostKeyPinning.parseHostKey(publicKey) else {
            throw TartError.commandFailed(what: "pin host key of \(vm)", stderr: "not an ssh-ed25519 public key")
        }
        guard vm.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw TartError.commandFailed(what: "pin host key of \(vm)", stderr: "unsafe instance id")
        }
        let directory = try knownHostsDirectory()
        let file = directory.appendingPathComponent("\(vm).known_hosts")
        // Created 0600 from the first byte, like every other private file.
        try Paths.writePrivateFile(Data("\(vm) \(key)\n".utf8), to: file)
        state.withLock { $0.files[vm] = file }
        // A later success means the latest connection is verified again.
        bestEffort("ssh", "clearing the unpinned-host-key marker") {
            if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
        }
    }

    func forget(vm: String) {
        guard let file = state.withLock({ $0.files.removeValue(forKey: vm) }) else { return }
        bestEffort(vm, "removing the pinned host key") { try FileManager.default.removeItem(at: file) }
    }

    func noteUnpinned(vm: String, reason: String) {
        let first = state.withLock { state -> Bool in
            defer { state.warned = true }
            return !state.warned
        }
        if first {
            Log.warn(
                vm,
                "could not pin the guest's SSH host key (\(reason)); connecting without host key verification. "
                    + "A hostile VM on a shared network could impersonate this one: set tart_softnet: true (docs/security.md)"
            )
        }
        bestEffort("ssh", "recording the unpinned-host-key marker") {
            try Paths.createPrivateDirectory(marker.deletingLastPathComponent())
            try Paths.writePrivateFile(Data("\(vm): \(reason)\n".utf8), to: marker)
        }
    }

    private func knownHostsDirectory() throws -> URL {
        try state.withLock { state -> URL in
            let made =
                state.directory
                ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("kinhin-known-hosts-\(UUID().uuidString)", isDirectory: true)
            try Paths.createPrivateDirectory(made)
            state.directory = made
            return made
        }
    }
}
