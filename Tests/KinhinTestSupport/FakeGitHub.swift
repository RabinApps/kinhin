import Foundation
import Synchronization

@testable import KinhinKit

/// In-memory GitHub double with configurable queue depth.
final class FakeGitHub: GitHubServing, Sendable {
    private struct State: Sendable {
        var configureURL = "https://github.com/acme/widgets"
        var runnersByID: [Int: GHRunner] = [:]
        var nextRunnerID = 1
        var queueDepth = 0
        var queuedJobsCallCount = 0
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
        /// When set, `runningJobs` throws this error (simulates a token that
        /// can manage runners but cannot read queued/running jobs).
        var runningJobsError: GitHubError?
        var runningJobsCallCount = 0
        /// The API budget the fake reports (nil: unknown, like other forges).
        var rateLimit: ForgeRateLimit?
        /// Branch/tag, sha and fork flag cycled through the queued jobs.
        var queueRefs: [String] = []
        var queueShas: [String] = []
        var queueForks = false
        /// `.kinhin.yml` bodies keyed by "owner/name@ref" ("@default" when
        /// the read has no ref, i.e. the default branch).
        var projectFiles: [String: Data] = [:]
        var projectFileCalls: [String] = []
    }

    private let state = Mutex(State())

    var configureURL: String {
        get { state.withLock { $0.configureURL } }
        set { state.withLock { $0.configureURL = newValue } }
    }

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

    var runningJobsCallCount: Int { state.withLock { $0.runningJobsCallCount } }

    var rateLimit: ForgeRateLimit? {
        get { state.withLock { $0.rateLimit } }
        set { state.withLock { $0.rateLimit = newValue } }
    }

    var queueRefs: [String] {
        get { state.withLock { $0.queueRefs } }
        set { state.withLock { $0.queueRefs = newValue } }
    }

    var queueShas: [String] {
        get { state.withLock { $0.queueShas } }
        set { state.withLock { $0.queueShas = newValue } }
    }

    var queueForks: Bool {
        get { state.withLock { $0.queueForks } }
        set { state.withLock { $0.queueForks = newValue } }
    }

    var projectFiles: [String: Data] {
        get { state.withLock { $0.projectFiles } }
        set { state.withLock { $0.projectFiles = newValue } }
    }

    var projectFileCalls: [String] { state.withLock { $0.projectFileCalls } }

    func projectFile(repository: String, ref: String?) async throws -> Data? {
        state.withLock { state in
            let key = "\(repository)@\(ref ?? "default")"
            state.projectFileCalls.append(key)
            return state.projectFiles[key]
        }
    }

    var registrationTokenCalls: Int { state.withLock { $0.registrationTokenCalls } }

    var deletedRunnerIDs: [Int] { state.withLock { $0.deletedRunnerIDs } }

    var failQueue: Bool {
        get { state.withLock { $0.failQueue } }
        set { state.withLock { $0.failQueue = newValue } }
    }

    /// When set, token minting fails with 403 (no runner-admin permission).
    var permissionDenied: Bool {
        get { state.withLock { $0.permissionDenied } }
        set { state.withLock { $0.permissionDenied = newValue } }
    }

    /// When set, token minting fails with 401 (bad/expired token).
    var unauthorized: Bool {
        get { state.withLock { $0.unauthorized } }
        set { state.withLock { $0.unauthorized = newValue } }
    }

    /// When set, token minting fails with 404 (scope not reachable).
    var notFound: Bool {
        get { state.withLock { $0.notFound } }
        set { state.withLock { $0.notFound = newValue } }
    }

    /// When set, token minting fails with exactly this error.
    var tokenError: GitHubError? {
        get { state.withLock { $0.tokenError } }
        set { state.withLock { $0.tokenError = newValue } }
    }

    /// Repositories cycled through the queued jobs' `repository` field
    /// (simulates org-scope attribution). Empty → jobs have nil repository.
    var queueRepos: [String] {
        get { state.withLock { $0.queueRepos } }
        set { state.withLock { $0.queueRepos = newValue } }
    }

    /// Scripted in-progress jobs returned by `runningJobs` (simulates the
    /// jobs API's runner_name → repo mapping).
    var running: [RunningJob] {
        get { state.withLock { $0.running } }
        set { state.withLock { $0.running = newValue } }
    }

    /// When set, `runningJobs` throws this error (simulates a token that can
    /// manage runners but cannot read queued/running jobs).
    var runningJobsError: GitHubError? {
        get { state.withLock { $0.runningJobsError } }
        set { state.withLock { $0.runningJobsError = newValue } }
    }

    func fetchRegistrationToken() async throws -> RegistrationToken {
        let calls = state.withLock { state -> Int in
            state.registrationTokenCalls += 1
            return state.registrationTokenCalls
        }
        if let custom = state.withLock({ $0.tokenError }) { throw custom }
        if state.withLock({ $0.permissionDenied }) {
            throw GitHubError.forbidden("Resource not accessible by personal access token")
        }
        if state.withLock({ $0.unauthorized }) { throw GitHubError.unauthorized }
        if state.withLock({ $0.notFound }) {
            throw GitHubError.notFound("/orgs/acme/actions/runners/registration-token")
        }
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
        let (depth, failing, repos, refs, shas, fork) = state.withLock {
            state -> (Int, Bool, [String], [String], [String], Bool) in
            state.queuedJobsCallCount += 1
            return (
                state.queueDepth, state.failQueue, state.queueRepos, state.queueRefs, state.queueShas, state.queueForks
            )
        }
        if failing { throw GitHubError.http(0, "offline") }
        return (0..<depth).map { i in
            QueuedJob(
                runID: 1, jobID: i, name: "job \(i)", labels: labels.sorted(),
                repository: repos.isEmpty ? nil : repos[i % repos.count],
                ref: refs.isEmpty ? nil : refs[i % refs.count], sha: shas.isEmpty ? nil : shas[i % shas.count],
                isFork: fork)
        }
    }

    func runningJobs(matching labels: Set<String>) async throws -> [RunningJob] {
        return try state.withLock { state in
            state.runningJobsCallCount += 1
            if let error = state.runningJobsError { throw error }
            return state.running
        }
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
