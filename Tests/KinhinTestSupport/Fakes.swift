import Foundation
import Synchronization

@testable import KinhinKit

/// Scriptable fake for the tart binary.
final class FakeTart: TartControlling, @unchecked Sendable {
    private struct State: Sendable {
        var vms: [String: TartVM] = [:]
        var cloneCalls: [(source: String, name: String)] = []
        var deleteCalls: [String] = []
        var pullCalls: [String] = []
        var runCalls: [String] = []
        /// Host directories shared into each booted VM, per run call.
        var runMounts: [[String]] = []
        var stopCalls: [String] = []
        var failNextClone = false
        /// Makes every `list()` throw, like `tart list` failing to launch.
        var failList = false
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
    /// Host directories shared into each booted VM, per run call.
    var runMounts: [[String]] { state.withLock { $0.runMounts } }
    var stopCalls: [String] { state.withLock { $0.stopCalls } }
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
            state.cloneCalls.append((source, name))
            state.vms[name] = TartVM(name: name, source: source, status: "running")
        }
    }

    func run(name: String) async throws {
        try await run(name: name, mounts: [])
    }

    func run(name: String, mounts: [String]) async throws {
        state.withLock { state in
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
        "192.168.64.\(Int.random(in: 2...250))"
    }

    func sshExec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws
        -> ShellResult
    {
        ShellResult(exitCode: 0, stdout: "", stderr: "")
    }

    func stop(name: String) async throws {
        state.withLock { $0.stopCalls.append(name) }
    }

    func delete(name: String) async throws {
        state.withLock { state in
            state.deleteCalls.append(name)
            state.vms.removeValue(forKey: name)
        }
    }

    func pull(image: String) async throws {
        state.withLock { $0.pullCalls.append(image) }
    }
}

/// In-memory GitHub double with configurable queue depth.
final class FakeGitHub: GitHubServing, @unchecked Sendable {
    var configureURL = "https://github.com/acme/widgets"

    private struct State: Sendable {
        var runnersByID: [Int: GHRunner] = [:]
        var nextRunnerID = 1
        var queueDepth = 0
        var queuedJobsCallCount = 0
        var registrationTokenCalls = 0
        var deletedRunnerIDs: [Int] = []
        var failQueue = false
    }

    private let state = Mutex(State())

    var runnersByID: [Int: GHRunner] {
        get { state.withLock { $0.runnersByID } }
        set { state.withLock { $0.runnersByID = newValue } }
    }

    var nextRunnerID: Int { state.withLock { $0.nextRunnerID } }

    var queueDepth: Int {
        get { state.withLock { $0.queueDepth } }
        set { state.withLock { $0.queueDepth = newValue } }
    }

    var queuedJobsCallCount: Int { state.withLock { $0.queuedJobsCallCount } }

    var registrationTokenCalls: Int { state.withLock { $0.registrationTokenCalls } }

    var deletedRunnerIDs: [Int] { state.withLock { $0.deletedRunnerIDs } }

    var failQueue: Bool {
        get { state.withLock { $0.failQueue } }
        set { state.withLock { $0.failQueue = newValue } }
    }

    /// When set, token minting fails with 403 (no runner-admin permission).
    var permissionDenied = false
    /// When set, token minting fails with 401 (bad/expired token).
    var unauthorized = false
    /// When set, token minting fails with 404 (scope not reachable).
    var notFound = false
    /// When set, token minting fails with exactly this error.
    var tokenError: GitHubError?
    /// Repositories cycled through the queued jobs' `repository` field
    /// (simulates org-scope attribution). Empty → jobs have nil repository.
    var queueRepos: [String] = []
    /// Scripted in-progress jobs returned by `runningJobs` (simulates the
    /// jobs API's runner_name → repo mapping).
    var running: [RunningJob] = []
    /// When set, `runningJobs` throws this error (simulates a token that can
    /// manage runners but cannot read queued/running jobs).
    var runningJobsError: (any Error)?

    func fetchRegistrationToken() async throws -> RegistrationToken {
        let calls = state.withLock { state -> Int in
            state.registrationTokenCalls += 1
            return state.registrationTokenCalls
        }
        if let custom = tokenError { throw custom }
        if permissionDenied { throw GitHubError.forbidden("Resource not accessible by personal access token") }
        if unauthorized { throw GitHubError.unauthorized }
        if notFound { throw GitHubError.notFound("/orgs/acme/actions/runners/registration-token") }
        return RegistrationToken(token: "RT-\(calls)", expiresAt: Date().addingTimeInterval(3600))
    }

    func listRunners() async throws -> [GHRunner] {
        Array(state.withLock { $0.runnersByID.values })
    }

    func deleteRunner(id: Int) async throws {
        state.withLock { state in
            state.deletedRunnerIDs.append(id)
            state.runnersByID.removeValue(forKey: id)
        }
    }

    func queuedJobs(matching labels: Set<String>) async throws -> [QueuedJob] {
        let (depth, failing) = state.withLock { state in
            state.queuedJobsCallCount += 1
            return (state.queueDepth, state.failQueue)
        }
        if failing { throw GitHubError.http(0, "offline") }
        return (0..<depth).map { i in
            QueuedJob(
                runID: 1, jobID: i, name: "job \(i)", labels: labels.sorted(),
                repository: queueRepos.isEmpty ? nil : queueRepos[i % queueRepos.count])
        }
    }

    func runningJobs(matching labels: Set<String>) async throws -> [RunningJob] {
        if let error = runningJobsError { throw error }
        return running
    }

    /// Simulate the runner registering on GitHub.
    func register(name: String, busy: Bool = false) {
        state.withLock { state in
            let id = state.nextRunnerID
            state.nextRunnerID += 1
            state.runnersByID[id] = GHRunner(id: id, name: name, status: "online", busy: busy, labels: [])
        }
    }

    /// Simulate ephemeral deregistration after the job.
    func deregister(name: String) {
        state.withLock { state in
            state.runnersByID = state.runnersByID.filter { $0.value.name != name }
        }
    }
}

/// SSH double that "registers" the runner when its script runs.
final class FakeSSH: SSHExecuting, @unchecked Sendable {
    var onExec: ((String) -> Void)?  // receives the VM name

    private struct State: Sendable {
        var scripts: [String] = []
        var timeouts: [TimeInterval] = []
    }

    private let state = Mutex(State())

    var scripts: [String] { state.withLock { $0.scripts } }
    var timeouts: [TimeInterval] { state.withLock { $0.timeouts } }

    /// When set, every exec fails with this text as stderr.
    var failWith: String?
    /// When set (and `failWith` is not), only the exec at this zero-based
    /// call index fails — lets tests fail a later step (e.g. the user
    /// provision script) while earlier steps succeed.
    var failOnCall: Int?

    func exec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws -> ShellResult {
        let (callIndex, failing) = state.withLock { state -> (Int, String?) in
            let callIndex = state.scripts.count
            state.scripts.append(script)
            state.timeouts.append(timeout)
            let failing: String?
            if let idx = failOnCall, idx == callIndex {
                failing = failWith ?? "injected failure"
            } else {
                failing = failWith
            }
            return (callIndex, failing)
        }
        onExec?(vm)
        if let failing {
            return ShellResult(exitCode: 1, stdout: "", stderr: failing)
        }
        return ShellResult(exitCode: 0, stdout: "runner started", stderr: "")
    }
}

/// Scratch-directory fleet store for tests.
func makeTestStore() -> FleetStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("kinhin-tests-\(UUID().uuidString)", isDirectory: true)
    // Best-effort: if the scratch dir can't be created, the store fails on first use.
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return FleetStore(directory: dir)
}

func makeTestConfig(repo: String = "acme/widgets") -> KinhinConfig {
    var cfg = KinhinConfig.default
    cfg.repo = repo
    cfg.labels = ["kinhin"]
    cfg.pollInterval = 5
    cfg.vmBootTimeout = 30
    return cfg
}

let testHost = HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true)
