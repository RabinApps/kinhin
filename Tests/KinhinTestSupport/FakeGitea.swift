import Foundation
import Synchronization

@testable import KinhinKit

/// In-memory Gitea-family Forge double with configurable queue depth and a
/// content cache surface (`projectFiles`/`projectFileCalls`) mirroring
/// `FakeGitHub`, so the same per-(repo, sha) dedup and fork-default-branch
/// tests can run against every file-capable forge.
final class FakeGitea: Forge, Sendable {
    private struct State: Sendable {
        var account = "gitea"
        var labels: [String] = ["kinhin"]
        var registrationToken = "gt"
        var queueDepth = 0
        var queuedJobsCallCount = 0
        var runnerList: [ForgeRunner] = []
        var runningJobs: [ForgeJob] = []
        var queueForks = false
        var queueRefs: [String] = []
        var queueShas: [String] = []
        var projectFiles: [String: Data] = [:]
        var projectFileCalls: [String] = []
    }

    private let state = Mutex(State())

    var account: String { state.withLock { $0.account } }
    var credentials: ForgeCredentials { .gitea(token: "t", scope: "acme/api", instance: "https://gitea.example.com") }
    var labels: [String] { state.withLock { $0.labels } }
    var registration: ForgeRegistration { .sharedLongLived }
    var exitSemantics: ForgeExitSemantics { .idleGrace }
    /// Per-repo attribution only when the scope spans repos: the real Gitea
    /// forge takes the protocol default (`!scope.contains("/")`), so the fake
    /// derives it from its scope too instead of hardcoding a flag.
    var attributesByRepo: Bool { !credentials.scope.contains("/") }
    var rateLimit: ForgeRateLimit? { nil }
    var name: String { "gitea" }
    var id: ForgeID { .gitea }

    var queueDepth: Int {
        get { state.withLock { $0.queueDepth } }
        set { state.withLock { $0.queueDepth = newValue } }
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

    func registrationURL() -> String { "https://gitea.example.com" }

    func mintRegistrationToken() async throws -> String { state.withLock { $0.registrationToken } }

    func registrationTokens(runnerNames: [String], labels: [String]) async throws -> [String: String] {
        let token = try await mintRegistrationToken()
        return Dictionary(uniqueKeysWithValues: runnerNames.map { ($0, token) })
    }

    func runners() async throws -> [ForgeRunner] { state.withLock { $0.runnerList } }

    /// Like the real forge: validate the id (the engine only passes ids that
    /// came from `runners()`) before any request, so a malformed one fails
    /// identically instead of silently succeeding.
    func deleteRunner(id: String) async throws {
        _ = try numericRunnerID(id)
    }

    func queuedJobs() async throws -> [ForgeJob] {
        let (depth, _, refs, shas, fork) = state.withLock {
            state -> (Int, [String], [String], [String], Bool) in
            state.queuedJobsCallCount += 1
            return (state.queueDepth, [], state.queueRefs, state.queueShas, state.queueForks)
        }
        return (0..<depth).map { i in
            ForgeJob(
                name: "job \(i)", runnerName: nil,
                repository: "acme/api",
                ref: refs.isEmpty ? nil : refs[i % refs.count],
                sha: shas.isEmpty ? nil : shas[i % shas.count],
                isFork: fork
            )
        }
    }

    func runningJobs() async throws -> [ForgeJob] { state.withLock { $0.runningJobs } }

    func projectFile(repository: String, ref: String?) async throws -> Data? {
        state.withLock { state in
            let key = "\(repository)@\(ref ?? "default")"
            state.projectFileCalls.append(key)
            return state.projectFiles[key]
        }
    }
}

/// In-memory GitLab Forge double with configurable queue depth and a content
/// cache surface (`projectFiles`/`projectFileCalls`) mirroring `FakeGitHub`,
/// so the same per-(repo, sha) dedup and fork-default-branch tests can run
/// against every file-capable forge.
final class FakeGitLab: Forge, Sendable {
    private struct State: Sendable {
        var account = "gitlab"
        var labels: [String] = ["kinhin"]
        var queueDepth = 0
        var queuedJobsCallCount = 0
        var runnerList: [ForgeRunner] = []
        var runningJobs: [ForgeJob] = []
        var queueForks = false
        /// Extra job labels beyond the account's own (pool markers).
        var queueExtraLabels: [String] = []
        var queueRefs: [String] = []
        var queueShas: [String] = []
        var projectFiles: [String: Data] = [:]
        var projectFileCalls: [String] = []
    }

    private let state = Mutex(State())

    var account: String { state.withLock { $0.account } }
    var credentials: ForgeCredentials { .gitlab(token: "t", scope: "acme/api", instance: "https://gitlab.example.com") }
    var labels: [String] { state.withLock { $0.labels } }
    var registration: ForgeRegistration { .perRunner }
    var exitSemantics: ForgeExitSemantics { .deregisters }
    /// Per-repo attribution only for a scope that spans repos: the real forge
    /// reports it when the resolved scope is a group, so the fake derives it
    /// from its scope (a path without a slash is one project) instead of
    /// hardcoding a flag.
    var attributesByRepo: Bool { !credentials.scope.contains("/") }
    var rateLimit: ForgeRateLimit? { nil }
    var name: String { "gitlab" }
    var id: ForgeID { .gitlab }

    var queueDepth: Int {
        get { state.withLock { $0.queueDepth } }
        set { state.withLock { $0.queueDepth = newValue } }
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

    /// Labels the fake's queued jobs carry beyond the account's own. The real
    /// forge reports the job's tags, which always include every account label
    /// — that is exactly what `queuedJobs` filters on — so the fake builds
    /// them the same way and tests can add pool markers on top.
    var queueExtraLabels: [String] {
        get { state.withLock { $0.queueExtraLabels } }
        set { state.withLock { $0.queueExtraLabels = newValue } }
    }

    var projectFiles: [String: Data] {
        get { state.withLock { $0.projectFiles } }
        set { state.withLock { $0.projectFiles = newValue } }
    }

    var projectFileCalls: [String] { state.withLock { $0.projectFileCalls } }

    func registrationURL() -> String { "https://gitlab.example.com" }

    func mintRegistrationToken() async throws -> String {
        throw EngineError.registrationFailed(vm: account, stderr: "GitLab has no shared registration token")
    }

    func registrationTokens(runnerNames: [String], labels: [String]) async throws -> [String: String] {
        var tokens: [String: String] = [:]
        for name in runnerNames { tokens[name] = "glrt-\(name)" }
        return tokens
    }

    func runners() async throws -> [ForgeRunner] { state.withLock { $0.runnerList } }

    /// Like the real forge: validate the id (the engine only passes ids that
    /// came from `runners()`) before any request, so a malformed one fails
    /// identically instead of silently succeeding.
    func deleteRunner(id: String) async throws {
        _ = try numericRunnerID(id)
    }

    func queuedJobs() async throws -> [ForgeJob] {
        let (depth, refs, shas, fork, extra) = state.withLock {
            state -> (Int, [String], [String], Bool, [String]) in
            state.queuedJobsCallCount += 1
            return (state.queueDepth, state.queueRefs, state.queueShas, state.queueForks, state.queueExtraLabels)
        }
        // Every job a real GitLab reports carries the account labels (the
        // forge drops the ones that don't), plus whatever tags it asked for.
        let jobLabels = labels + extra
        return (0..<depth).map { i in
            ForgeJob(
                name: "job \(i)", runnerName: nil,
                repository: "acme/api",
                labels: jobLabels,
                ref: refs.isEmpty ? nil : refs[i % refs.count],
                sha: shas.isEmpty ? nil : shas[i % shas.count],
                isFork: fork
            )
        }
    }

    func runningJobs() async throws -> [ForgeJob] { state.withLock { $0.runningJobs } }

    func projectFile(repository: String, ref: String?) async throws -> Data? {
        state.withLock { state in
            let key = "\(repository)@\(ref ?? "default")"
            state.projectFileCalls.append(key)
            return state.projectFiles[key]
        }
    }
}
