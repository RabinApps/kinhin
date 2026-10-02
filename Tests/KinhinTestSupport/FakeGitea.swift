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
    var attributesByRepo: Bool { true }
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
    func deleteRunner(id: String) async throws {}

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
    var attributesByRepo: Bool { true }
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
    func deleteRunner(id: String) async throws {}

    func queuedJobs() async throws -> [ForgeJob] {
        let (depth, refs, shas, fork) = state.withLock {
            state -> (Int, [String], [String], Bool) in
            state.queuedJobsCallCount += 1
            return (state.queueDepth, state.queueRefs, state.queueShas, state.queueForks)
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
