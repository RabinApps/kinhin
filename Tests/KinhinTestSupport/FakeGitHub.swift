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
        var listRunnersCallCount = 0
        /// Makes `listRunners` throw, like an API outage.
        var failRunnerList = false
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
        /// What `pipelineDetail` answers, and the runner names it was asked for.
        var pipeline: PipelineDetail?
        var pipelineRunnerNames: [String] = []
        var jobLogs: [String: String] = [:]
        /// Branch/tag, sha and fork flag cycled through the queued jobs.
        var queueRefs: [String] = []
        var queueShas: [String] = []
        /// Labels every queued job requests beyond the fleet's own (e.g. an image label).
        var queueExtraLabels: [String] = []
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

    /// How many times the runner list was fetched.
    var listRunnersCallCount: Int { state.withLock { $0.listRunnersCallCount } }

    /// Makes `listRunners` throw.
    var failRunnerList: Bool {
        get { state.withLock { $0.failRunnerList } }
        set { state.withLock { $0.failRunnerList = newValue } }
    }

    var runningJobsCallCount: Int { state.withLock { $0.runningJobsCallCount } }

    var rateLimit: ForgeRateLimit? {
        get { state.withLock { $0.rateLimit } }
        set { state.withLock { $0.rateLimit = newValue } }
    }

    var queueRefs: [String] {
        get { state.withLock { $0.queueRefs } }
        set { state.withLock { $0.queueRefs = newValue } }
    }

    var queueExtraLabels: [String] {
        get { state.withLock { $0.queueExtraLabels } }
        set { state.withLock { $0.queueExtraLabels = newValue } }
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

    var pipeline: PipelineDetail? {
        get { state.withLock { $0.pipeline } }
        set { state.withLock { $0.pipeline = newValue } }
    }

    /// Raw job logs by "owner/name|jobID".
    var jobLogs: [String: String] {
        get { state.withLock { $0.jobLogs } }
        set { state.withLock { $0.jobLogs = newValue } }
    }

    func jobLog(repository: String, jobID: Int) async throws -> String? {
        state.withLock { $0.jobLogs["\(repository)|\(jobID)"] }
    }

    var pipelineRunnerNames: [String] { state.withLock { $0.pipelineRunnerNames } }

    func pipelineDetail(runnerName: String) async throws -> PipelineDetail? {
        state.withLock { state in
            state.pipelineRunnerNames.append(runnerName)
            return state.pipeline
        }
    }

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
        try state.withLock { state in
            state.listRunnersCallCount += 1
            if state.failRunnerList { throw URLError(.notConnectedToInternet) }
            return Array(state.runnersByID.values)
        }
    }

    func deleteRunner(id: Int) async throws {
        state.withLock { state in
            state.deletedRunnerIDs.append(id)
            state.runnersByID.removeValue(forKey: id)
        }
    }

    func queuedJobs(matching labels: Set<String>) async throws -> [QueuedJob] {
        let (depth, failing, repos, refs, shas, fork, extra) = state.withLock {
            state -> (Int, Bool, [String], [String], [String], Bool, [String]) in
            state.queuedJobsCallCount += 1
            return (
                state.queueDepth, state.failQueue, state.queueRepos, state.queueRefs, state.queueShas, state.queueForks,
                state.queueExtraLabels
            )
        }
        if failing { throw GitHubError.http(0, "offline") }
        return (0..<depth).map { i in
            QueuedJob(
                runID: 1, jobID: i, name: "job \(i)", labels: labels.sorted() + extra,
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

    func cancelWorkflowRun(ids: [Int]) async throws -> Bool { true }
    func skipWorkflowRun(ids: [Int]) async throws -> Bool { true }

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

extension FakeGitHub: Forge {
    var id: ForgeID { .github }
    var name: String { "github" }
    var credentials: ForgeCredentials { .github(token: "t", scope: "acme/widgets") }
    var account: String { "github" }
    var labels: [String] { [] }
    var registration: ForgeRegistration { .sharedShortLived }
    var exitSemantics: ForgeExitSemantics { .deregisters }
    var attributesByRepo: Bool { true }
    func registrationURL() -> String { configureURL }
    func mintRegistrationToken() async throws -> String {
        try await fetchRegistrationToken().token
    }
    func registrationTokens(runnerNames: [String], labels: [String]) async throws -> [String: String] {
        let token = try await mintRegistrationToken()
        return Dictionary(uniqueKeysWithValues: runnerNames.map { ($0, token) })
    }
    func runners() async throws -> [ForgeRunner] {
        try await listRunners().map { ForgeRunner(id: String($0.id), name: $0.name, busy: $0.busy) }
    }
    func deleteRunner(id: String) async throws {
        try await deleteRunner(id: Int(id) ?? 0)
    }
    func queuedJobs() async throws -> [ForgeJob] {
        try await queuedJobs(matching: Set(labels)).map {
            ForgeJob(
                name: $0.name, runnerName: nil, repository: $0.repository, labels: $0.labels, ref: $0.ref, sha: $0.sha,
                isFork: $0.isFork)
        }
    }
    func runningJobs() async throws -> [ForgeJob] {
        try await runningJobs(matching: Set(labels)).map {
            ForgeJob(name: $0.name, runnerName: $0.runnerName, repository: $0.repository)
        }
    }
}
