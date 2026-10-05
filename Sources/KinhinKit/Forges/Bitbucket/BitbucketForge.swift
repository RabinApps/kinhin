import Foundation
import Synchronization

// MARK: - Bitbucket busy state

// MARK: - Bitbucket adapter

/// Forge implementation for Bitbucket Cloud Pipelines self-hosted runners
/// (macOS and Linux shell runners; the Docker runner is out of scope).
///
/// A runner is created on the forge per runner name (`.perRunner`): the
/// create response carries the OAuth client id/secret the agent
/// authenticates with, and the secret is only ever shown once, so kinhin
/// stores the bundle (runner UUID, OAuth client id, secret) as the runner's
/// token. The runner serves every step assigned to it and stays registered
/// (Bitbucket's runner protocol has no single-job mode), so the Gitea-style
/// "busy, then idle for a grace period" watch detects a finished instance;
/// teardown and `deleteVMRecord` delete the instance's runners through the
/// API.
///
/// The public API exposes no queued-steps endpoint, so demand comes from
/// the scope's active pipelines' steps: a repository-scoped account polls
/// its one repo; a workspace-scoped account polls the recently active
/// repositories (one page of repos, one page of pipelines each), which
/// keeps the poll inside Bitbucket's roughly 1000 requests/hour budget.
/// The public step payload does not expose `runs_on` either, so every step
/// of an active pipeline counts as this fleet's demand — the runner itself
/// matches `runs-on` labels against the labels it registered with (the
/// account's labels plus `self.hosted` and the platform marker).
/// Whether any step of the scope is running right now — shared because
/// runner lists and running-job reads happen on different tasks. A box
/// (not a plain property) so the forge stays a value type.
final class BitbucketBusyState: Sendable {
    private let running = Mutex(false)

    var isBusy: Bool { running.withLock { $0 } }

    func setBusy(_ busy: Bool) {
        running.withLock { $0 = busy }
    }
}

struct BitbucketForge: Forge {
    let id: ForgeID = .bitbucket
    let name = "bitbucket"
    let account: String
    let credentials: ForgeCredentials
    /// The labels the runners register with (they include `self.hosted` and
    /// the platform marker; see `BitbucketForge.runnerLabels`).
    let labels: [String]
    let registration: ForgeRegistration = .perRunner
    let exitSemantics: ForgeExitSemantics = .idleGrace
    let client: BitbucketClient
    let scope: BitbucketScope
    /// The workspace UUID for the agents' start command (`--accountUuid`).
    let workspaceUUID: String
    /// The repository UUID (repo-scoped runners only), `--repositoryUuid`.
    let repositoryUUID: String?
    /// Every instance's exit watch lists runners each second; share the list.
    let runnerList: SharedListCache<BitbucketRunner>
    /// Queued and running steps come from one poll read per interval.
    let jobList: SharedListCache<BitbucketJob>
    /// Whether any step is running right now. Steps do not name the runner
    /// that took them, so a running step marks every runner of the scope
    /// busy — the same coarse signal the Gitea-family forge derives from
    /// its runners' own busy state.
    private let busyState = BitbucketBusyState()

    init(
        credentials: ForgeCredentials, labels: [String], client: BitbucketClient, scope: BitbucketScope,
        workspaceUUID: String, repositoryUUID: String?, account: String = "bitbucket",
        listTTL: TimeInterval = 3
    ) {
        self.account = account
        self.credentials = credentials
        self.labels = labels
        self.client = client
        self.scope = scope
        self.workspaceUUID = workspaceUUID
        self.repositoryUUID = repositoryUUID
        self.runnerList = SharedListCache(ttl: listTTL)
        self.jobList = SharedListCache(ttl: listTTL)
    }

    /// Builds the forge, resolving the scope and the agent start command's
    /// UUIDs up front (fails fast on a bad token, workspace or repository).
    static func make(
        credentials: BitbucketCredentials, labels: [String], account: String = "bitbucket",
        session: URLSession? = nil
    ) async throws -> BitbucketForge {
        let client = BitbucketClient(credentials: credentials, session: session)
        let scope = BitbucketScope(credentials: credentials)
        try await client.verifyScope()
        let workspaceUUID = try await client.workspaceUUID(scope: scope)
        let repositoryUUID = try await client.repositoryUUID(scope: scope)
        return BitbucketForge(
            credentials: ForgeCredentials(forge: .bitbucket, token: credentials.token, scope: credentials.scope),
            labels: labels, client: client, scope: scope, workspaceUUID: workspaceUUID,
            repositoryUUID: repositoryUUID, account: account)
    }

    /// The labels a runner registers with: the self-hosted and platform
    /// markers every `runs-on:` needs, plus the account's own labels.
    static func runnerLabels(accountLabels: [String], platform: String) -> [String] {
        ["self.hosted", platform] + accountLabels
    }

    /// The Bitbucket platform label for a pool, from the runtime markers the
    /// pool's GitHub-style labels carry: Linux runtimes (containers) get
    /// `linux.shell`, macOS runtimes (VMs, the host) get `macos`.
    static func platformMarker(forPoolLabels poolLabels: [String]) -> String {
        let linuxMarkers: Set<String> = ["kinhin-container", "kinhin-docker"]
        return poolLabels.contains(where: linuxMarkers.contains) ? "linux.shell" : "macos"
    }

    /// How a runner's per-runner credential bundle is assembled: everything
    /// the runner start command needs — workspace UUID (`--accountUuid`),
    /// repository UUID (`--repositoryUuid`, empty on workspace scopes),
    /// runner UUID (`--runnerUuid`), OAuth client id and OAuth client secret
    /// (which exists only in the create response). Joined with `|`, a
    /// character UUIDs and OAuth ids do not contain.
    func credentialBundle(runner: BitbucketRunner) -> String? {
        guard let oauth = runner.oauthClient, let secret = oauth.secret, !secret.isEmpty else { return nil }
        return [workspaceUUID, repositoryUUID ?? "", runner.uuid, oauth.id, secret].joined(separator: "|")
    }

    /// Workspace scopes serve every repository, so they attribute by repo.
    var attributesByRepo: Bool {
        if case .workspace = scope { return true }
        return false
    }

    /// Runners are created per name and identified by UUID; the agent talks
    /// to Bitbucket's API directly, there is no URL to join.
    func registrationURL() -> String {
        "https://api.bitbucket.org"
    }

    func mintRegistrationToken() async throws -> String {
        throw EngineError.registrationFailed(
            vm: account, stderr: "Bitbucket has no shared registration token; runners are created per instance")
    }

    /// Creates one runner per name with the fleet's labels, returning
    /// name → credential bundle (`credentialBundle`). The OAuth secret is
    /// only ever in the create response, so this is the only moment it can
    /// be captured. The runner's platform label comes from the pool's
    /// runtime markers (`platformMarker`).
    func registrationTokens(runnerNames: [String], labels poolLabels: [String]) async throws -> [String: String] {
        let runnerLabels = Self.runnerLabels(
            accountLabels: labels, platform: Self.platformMarker(forPoolLabels: poolLabels))
        var tokens: [String: String] = [:]
        defer { runnerList.invalidate() }  // the new runners must show up in the next list
        for name in runnerNames {
            let runner = try await client.createRunner(scope: scope, name: name, labels: runnerLabels)
            guard let bundle = credentialBundle(runner: runner) else {
                throw BitbucketError.missingOAuthClientSecret(name)
            }
            tokens[name] = bundle
        }
        return tokens
    }

    /// The scope's runners, busy while any step is running.
    func runners() async throws -> [ForgeRunner] {
        let runners = try await runnerList.elements { try await client.listRunners(scope: scope) }
        return runners.map { runner in
            ForgeRunner(
                id: runner.uuid, name: runner.name, busy: busyState.isBusy, online: runner.isOnline)
        }
    }

    func deleteRunner(id: String) async throws {
        defer { runnerList.invalidate() }
        try await client.deleteRunner(scope: scope, uuid: id)
    }

    /// Queued steps of the scope's active pipelines. The public API does
    /// not expose a step's `runs-on` yet, so every step counts; once it
    /// does, `isOurs` already filters. Attribution is by repository.
    func queuedJobs() async throws -> [ForgeJob] {
        try await jobs().filter { $0.isQueued && isOurs($0) }.map {
            ForgeJob(name: $0.name, runnerName: nil, repository: $0.repository, labels: $0.runsOn)
        }
    }

    /// Running steps (they mark every runner of the scope busy — see
    /// `hasRunningSteps`).
    func runningJobs() async throws -> [ForgeJob] {
        let jobs = try await jobs().filter(\.isRunning)
        busyState.setBusy(!jobs.isEmpty)
        return jobs.filter(isOurs).map {
            ForgeJob(name: $0.name, runnerName: nil, repository: $0.repository, labels: $0.runsOn)
        }
    }

    /// The in-progress pipeline (preferring `repository`) with its steps as
    /// jobs. Which runner took a step is not public, so every running step is
    /// marked as this VM's; the API has no list of commands within a step.
    func pipelineDetail(runnerName: String, repository: String?) async throws -> PipelineDetail? {
        let repos = try await detailRepositories()
        let pipelines = try await client.activePipelines(scope: scope, repos: repos)
        guard
            let active =
                pipelines.first(where: { $0.repository == repository && $0.steps.contains(where: \.isRunning) })
                ?? pipelines.first(where: { $0.steps.contains(where: \.isRunning) })
        else { return nil }
        let mapped = active.steps.map { step in
            PipelineJob(
                id: step.uuid, name: step.name ?? "step", state: Self.state(step),
                startedAt: PipelineParsing.date(step.startedOn), finishedAt: PipelineParsing.date(step.completedOn),
                isCurrent: step.isRunning, logRef: "\(active.repository)|\(active.pipeline.uuid)|\(step.uuid)")
        }
        let number = active.pipeline.buildNumber
        return PipelineDetail(
            forge: .bitbucket, title: number.map { "Pipeline #\($0)" } ?? "Pipeline", repository: active.repository,
            ref: active.pipeline.refName, sha: active.pipeline.commit,
            url: number.map { "https://bitbucket.org/\(active.repository)/pipelines/results/\($0)" },
            state: PipelineDetail.aggregate(mapped.map(\.state)),
            startedAt: PipelineParsing.date(active.pipeline.createdOn), jobs: mapped, granularity: .job)
    }

    /// A step's log; a Bitbucket step is the unit here, so `step` is ignored.
    func pipelineLog(job: PipelineJob, step: PipelineStep?) async throws -> PipelineLog? {
        let parts = job.logRef?.split(separator: "|", omittingEmptySubsequences: false).map(String.init) ?? []
        guard parts.count == 3 else { return nil }
        let raw = try await client.stepLog(repository: parts[0], pipeline: parts[1], step: parts[2])
        let (text, truncated) = PipelineLogText.clean(raw)
        return PipelineLog(text: text, scope: .job, truncated: truncated)
    }

    static func state(_ step: BitbucketStep) -> PipelineStepState {
        switch step.stateName {
        case "IN_PROGRESS": return .running
        case "COMPLETED":
            switch step.resultName ?? "" {
            case "SUCCESSFUL": return .succeeded
            case "STOPPED": return .cancelled
            case "SKIPPED", "NOT_RUN": return .skipped
            default: return .failed  // FAILED, ERROR, EXPIRED
            }
        default: return .pending
        }
    }

    private func detailRepositories() async throws -> [String] {
        switch scope {
        case .workspace: return Array(try await client.activeRepositories(scope: scope).prefix(20))
        case .repository: return [scope.description]
        }
    }

    /// A step is this fleet's when the API does not say its `runs-on` (no
    /// filtering is possible yet) or when its `runs-on` includes every
    /// label — the same subset rule GitHub's `runs-on:` matching uses.
    func isOurs(_ job: BitbucketJob) -> Bool {
        job.runsOn.isEmpty || Set(labels).isSubset(of: Set(job.runsOn))
    }

    private func jobs() async throws -> [BitbucketJob] {
        let repos: [String]
        switch scope {
        case .workspace:
            repos = Array(try await client.activeRepositories(scope: scope).prefix(20))
        case .repository:
            repos = [scope.description]
        }
        return try await jobList.elements { try await client.activeJobs(scope: scope, repos: repos) }
    }
}
