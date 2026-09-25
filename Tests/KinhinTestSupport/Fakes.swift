import Foundation

@testable import KinhinKit

/// Scriptable fake for the tart binary.
final class FakeTart: TartControlling, @unchecked Sendable {
    private let lock = NSLock()
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

    func list() async throws -> [TartVM] {
        lock.lock(); defer { lock.unlock() }
        if failList { throw TartError.commandFailed(what: "list", stderr: "injected failure") }
        return Array(vms.values)
    }

    func clone(source: String, to name: String) async throws {
        lock.lock()
        if failNextClone {
            failNextClone = false  // one-shot failure semantics
            lock.unlock()
            throw TartError.commandFailed(what: "clone", stderr: "injected failure")
        }
        cloneCalls.append((source, name))
        vms[name] = TartVM(name: name, source: source, status: "running")
        lock.unlock()
    }

    func run(name: String) async throws {
        try await run(name: name, mounts: [])
    }

    func run(name: String, mounts: [String]) async throws {
        lock.lock()
        runCalls.append(name)
        runMounts.append(mounts)
        if let vm = vms[name] {
            vms[name] = TartVM(
                name: vm.name, source: vm.source, status: "running", cpu: vm.cpu, memoryMB: vm.memoryMB,
                diskGB: vm.diskGB)
        }
        lock.unlock()
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
        lock.lock(); stopCalls.append(name); lock.unlock()
    }

    func delete(name: String) async throws {
        lock.lock(); defer { lock.unlock() }
        deleteCalls.append(name)
        vms.removeValue(forKey: name)
    }

    func pull(image: String) async throws {
        lock.lock(); pullCalls.append(image); lock.unlock()
    }
}

/// In-memory GitHub double with configurable queue depth.
final class FakeGitHub: GitHubServing, @unchecked Sendable {
    var configureURL = "https://github.com/acme/widgets"
    private let lock = NSLock()
    var runnersByID: [Int: GHRunner] = [:]
    var nextRunnerID = 1
    var queueDepth = 0
    var registrationTokenCalls = 0
    var deletedRunnerIDs: [Int] = []
    var failQueue = false

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
        lock.lock(); registrationTokenCalls += 1
        let denied = permissionDenied
        let rejected = unauthorized
        let missing = notFound
        let custom = tokenError
        lock.unlock()
        if let custom { throw custom }
        if denied { throw GitHubError.forbidden("Resource not accessible by personal access token") }
        if rejected { throw GitHubError.unauthorized }
        if missing { throw GitHubError.notFound("/orgs/acme/actions/runners/registration-token") }
        return RegistrationToken(token: "RT-\(registrationTokenCalls)", expiresAt: Date().addingTimeInterval(3600))
    }

    func listRunners() async throws -> [GHRunner] {
        lock.lock(); defer { lock.unlock() }
        return Array(runnersByID.values)
    }

    func deleteRunner(id: Int) async throws {
        lock.lock(); defer { lock.unlock() }
        deletedRunnerIDs.append(id)
        runnersByID.removeValue(forKey: id)
    }

    func queuedJobs(matching labels: Set<String>) async throws -> [QueuedJob] {
        lock.lock()
        let depth = queueDepth
        let failing = failQueue
        lock.unlock()
        if failing { throw GitHubError.http(0, "offline") }
        return (0..<depth).map { i in
            QueuedJob(
                runID: 1, jobID: i, name: "job \(i)", labels: labels.sorted(),
                repository: queueRepos.isEmpty ? nil : queueRepos[i % queueRepos.count]
            )
        }
    }

    func runningJobs(matching labels: Set<String>) async throws -> [RunningJob] {
        if let error = runningJobsError { throw error }
        return running
    }

    /// Simulate the runner registering on GitHub.
    func register(name: String, busy: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        let id = nextRunnerID
        nextRunnerID += 1
        runnersByID[id] = GHRunner(id: id, name: name, status: "online", busy: busy, labels: [])
    }

    /// Simulate ephemeral deregistration after the job.
    func deregister(name: String) {
        lock.lock(); defer { lock.unlock() }
        runnersByID = runnersByID.filter { $0.value.name != name }
    }
}

/// SSH double that "registers" the runner when its script runs.
final class FakeSSH: SSHExecuting, @unchecked Sendable {
    var onExec: ((String) -> Void)?  // receives the VM name
    private let lock = NSLock()
    private(set) var scripts: [String] = []
    private(set) var timeouts: [TimeInterval] = []
    /// When set, every exec fails with this text as stderr.
    var failWith: String?
    /// When set (and `failWith` is not), only the exec at this zero-based
    /// call index fails — lets tests fail a later step (e.g. the user
    /// provision script) while earlier steps succeed.
    var failOnCall: Int?

    func exec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws -> ShellResult {
        lock.lock()
        let callIndex = scripts.count
        scripts.append(script)
        timeouts.append(timeout)
        let failing: String?
        if let idx = failOnCall, idx == callIndex {
            failing = failWith ?? "injected failure"
        } else {
            failing = failWith
        }
        lock.unlock()
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
