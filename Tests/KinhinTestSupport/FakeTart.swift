import Foundation
import Synchronization

@testable import KinhinKit

/// Scriptable fake for the tart binary.
final class FakeTart: TartControlling, Sendable {
    private struct State: Sendable {
        var vms: [String: TartVM] = [:]
        var cloneCalls: [(source: String, name: String)] = []
        var deleteCalls: [String] = []
        var pullCalls: [String] = []
        var runCalls: [String] = []
        /// Host directories shared into each booted VM, per run call.
        var runMounts: [[String]] = []
        var stopCalls: [String] = []
        var installKeyCalls: [(vm: String, user: String)] = []
        var createLinuxCalls: [String] = []
        var runWithDiskCalls: [(name: String, isoPath: String)] = []
        var failNextClone = false
        /// Makes every `list()` throw, like `tart list` failing to launch.
        var failList = false
        /// When set, the next (one-shot) call to the named operation fails.
        /// Keys are method nicknames: "clone", "run", "runWithDisk",
        /// "createLinux", "stop", "delete", "pull", "ip".
        var failNext: [String: String] = [:]
        /// Makes `ip(of:)` park (checked-throwing continuation) until
        /// `releaseIP` resumes it — models a runtime call that ignores
        /// cancellation and ends only on its own timeout.
        var parkedIPs: [CheckedContinuation<String, Error>] = []
        /// Set by `blockIP()`: the next `ip(of:)` parks.
        var parkNextIP = false
    }

    private let state = Mutex(State())

    var vms: [String: TartVM] {
        get { state.withLock { $0.vms } }
        set { state.withLock { $0.vms = newValue } }
    }

    var cloneCalls: [(source: String, name: String)] {
        state.withLock { $0.cloneCalls }
    }

    var deleteCalls: [String] { state.withLock { $0.deleteCalls } }
    var pullCalls: [String] { state.withLock { $0.pullCalls } }
    var runCalls: [String] { state.withLock { $0.runCalls } }
    var installKeyCalls: [(vm: String, user: String)] { state.withLock { $0.installKeyCalls } }
    /// Host directories shared into each booted VM, per run call.
    var runMounts: [[String]] { state.withLock { $0.runMounts } }
    var stopCalls: [String] { state.withLock { $0.stopCalls } }
    var createLinuxCalls: [String] { state.withLock { $0.createLinuxCalls } }
    var runWithDiskCalls: [(name: String, isoPath: String)] { state.withLock { $0.runWithDiskCalls } }
    /// One-shot: the next `clone` fails, the one after succeeds again.
    var failNextClone: Bool {
        get { state.withLock { $0.failNextClone } }
        set { state.withLock { $0.failNextClone = newValue } }
    }

    /// Makes every `list()` throw, like `tart list` failing to launch.
    var failList: Bool {
        get { state.withLock { $0.failList } }
        set { state.withLock { $0.failList = newValue } }
    }

    /// One-shot failures: `tart.failNext["runWithDisk"] = "boot failed"`
    /// makes the next `runWithDisk` throw `TartError.commandFailed` with that
    /// stderr (and every method after it succeed again).
    func failNext(_ operation: String, stderr: String) {
        state.withLock { $0.failNext[operation] = stderr }
    }

    /// True while at least one `ip(of:)` call is parked in `blockIP`.
    var isBlockedInIP: Bool {
        !state.withLock { $0.parkedIPs.isEmpty }
    }

    /// Parks the next `ip(of:)` call (after optional one-shot setup) until
    /// `releaseIP(_:)` resumes it with that address.
    func blockIP() {
        state.withLock { $0.parkNextIP = true }
    }

    /// Resumes every parked `ip(of:)` call, returning `ip`.
    func releaseIP(_ ip: String) {
        let parked = state.withLock { state -> [CheckedContinuation<String, Error>] in
            let parked = state.parkedIPs
            state.parkedIPs.removeAll()
            return parked
        }
        for continuation in parked { continuation.resume(returning: ip) }
    }

    func list() async throws -> [TartVM] {
        try state.withLock { state -> [TartVM] in
            if state.failList { throw TartError.commandFailed(what: "list", stderr: "injected failure") }
            return Array(state.vms.values)
        }
    }

    func clone(source: String, to name: String) async throws {
        try state.withLock { state in
            if state.failNextClone {
                state.failNextClone = false  // one-shot failure semantics
                throw TartError.commandFailed(what: "clone", stderr: "injected failure")
            }
            if let stderr = state.failNext.removeValue(forKey: "clone") {
                throw TartError.commandFailed(what: "clone", stderr: stderr)
            }
            state.cloneCalls.append((source, name))
            state.vms[name] = TartVM(name: name, source: source, status: "running")
        }
    }

    func run(name: String) async throws {
        try await run(name: name, mounts: [])
    }

    func run(name: String, mounts: [String]) async throws {
        try state.withLock { state in
            if let stderr = state.failNext.removeValue(forKey: "run") {
                throw TartError.commandFailed(what: "run", stderr: stderr)
            }
            state.runCalls.append(name)
            state.runMounts.append(mounts)
            if let vm = state.vms[name] {
                state.vms[name] = TartVM(
                    name: vm.name, source: vm.source, status: "running", cpu: vm.cpu, memoryMB: vm.memoryMB,
                    diskGB: vm.diskGB)
            }
        }
    }

    func ip(of name: String, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let park = state.withLock { state -> Bool in
                if state.parkNextIP {
                    state.parkNextIP = false
                    state.parkedIPs.append(continuation)
                    return true
                }
                return false
            }
            if !park { continuation.resume(returning: "192.168.64.\(Int.random(in: 2...250))") }
        }
    }

    func sshExec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws
        -> ShellResult
    {
        ShellResult(exitCode: 0, stdout: "", stderr: "")
    }

    func installGuestSSHKey(vm: String, user: String) async throws {
        try state.withLock { state in
            state.installKeyCalls.append((vm, user))
            if let stderr = state.failNext["installKey"] {
                throw TartError.commandFailed(what: "exec", stderr: stderr)
            }
        }
    }

    func allowKeys(_ key: String) async throws {
        // No-op fake; the production path also ignores this call.
    }

    func stop(name: String) async throws {
        try state.withLock { state in
            if let stderr = state.failNext.removeValue(forKey: "stop") {
                throw TartError.commandFailed(what: "stop", stderr: stderr)
            }
            state.stopCalls.append(name)
        }
    }

    func delete(name: String) async throws {
        try state.withLock { state in
            if let stderr = state.failNext.removeValue(forKey: "delete") {
                throw TartError.commandFailed(what: "delete", stderr: stderr)
            }
            state.deleteCalls.append(name)
            state.vms.removeValue(forKey: name)
        }
    }

    func pull(image: String) async throws {
        try state.withLock { state in
            if let stderr = state.failNext.removeValue(forKey: "pull") {
                throw TartError.commandFailed(what: "pull", stderr: stderr)
            }
            state.pullCalls.append(image)
        }
    }

    func createLinux(name: String) async throws {
        try state.withLock { state in
            if let stderr = state.failNext.removeValue(forKey: "createLinux") {
                throw TartError.commandFailed(what: "create", stderr: stderr)
            }
            state.createLinuxCalls.append(name)
            state.vms[name] = TartVM(name: name, source: "", status: "stopped")
        }
    }

    func runWithDisk(name: String, isoPath: String) async throws {
        try state.withLock { state in
            if let stderr = state.failNext.removeValue(forKey: "runWithDisk") {
                throw TartError.commandFailed(what: "run --disk", stderr: stderr)
            }
            state.runWithDiskCalls.append((name, isoPath))
            if let vm = state.vms[name] {
                state.vms[name] = TartVM(
                    name: vm.name, source: vm.source, status: "running", cpu: vm.cpu, memoryMB: vm.memoryMB,
                    diskGB: vm.diskGB)
            }
        }
    }
}
