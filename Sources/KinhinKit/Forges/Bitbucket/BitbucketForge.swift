import Foundation
import Synchronization

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
/// The public step payload does not expose `runs_on` either, so each
/// active pipeline's `bitbucket-pipelines.yml` is read at the pipeline's
/// commit (`BitbucketPipelinesFile`) and only steps that run on
/// `self.hosted` count as this fleet's demand; cloud steps and steps still
/// waiting behind a running one do not.

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
    /// The workspace's recently active repositories (workspace scopes). The
    /// list changes slowly and every demand read needs it, so it is read far
    /// less often than the pipelines are.
    let repositoryList: SharedListCache<String>
    /// The parsed `bitbucket-pipelines.yml` per repository commit.
    let pipelinesFiles = BitbucketPipelinesFileCache()
    /// Whether this token can list the scope's runners (a 403/404 is
    /// remembered; the engine then reads `unlistedRunnerActivity`).
    let runnerListSupport = RunnerListSupport()

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
        // A zero list TTL means "never cache" (tests); otherwise repos change slowly.
        self.repositoryList = SharedListCache(ttl: listTTL > 0 ? 30 : 0)
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
    /// The pool's own labels (its runtime marker, image labels, the
    /// architecture) join the account's, so a pool's routing labels reach the
    /// forge-side runner; labels naming the other platform are dropped so a
    /// runner never advertises both `macos` and `linux.shell`.
    static func runnerLabels(accountLabels: [String], poolLabels: [String] = [], platform: String) -> [String] {
        let conflicting: Set<String> = platform == "macos" ? ["linux.shell", "linux"] : ["macos"]
        var seen: Set<String> = []
        var labels: [String] = []
        for label in ["self.hosted", platform] + accountLabels + poolLabels {
            let key = label.lowercased()
            guard !conflicting.contains(key), seen.insert(key).inserted else { continue }
            labels.append(label)
        }
        return labels
    }

    /// The Bitbucket platform label for a pool, from the labels the pool's
    /// runners register with: a Linux runtime marker (`kinhin-container`,
    /// `kinhin-docker`) or an explicit `linux`/`linux.shell` label gives
    /// `linux.shell`; everything else (macOS VMs, the host) is `macos`. The
    /// guest OS is not known when runners are created, so a Tart *Linux* VM
    /// needs a `linux` label on its pool or image; the registration script
    /// fails, naming that label, when the guest disagrees.
    static func platformMarker(forPoolLabels poolLabels: [String]) -> String {
        let linuxLabels: Set<String> = ["kinhin-container", "kinhin-docker", "linux", "linux.shell"]
        return poolLabels.contains { linuxLabels.contains($0.lowercased()) } ? "linux.shell" : "macos"
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
        // Same union the Tart registration script derives its platform guard from.
        let runnerLabels = Self.runnerLabels(
            accountLabels: labels, poolLabels: poolLabels,
            platform: Self.platformMarker(forPoolLabels: poolLabels + labels))
        var tokens: [String: String] = [:]
        var created: [String] = []  // runner UUIDs of this call, deleted again when a later one fails
        defer { runnerList.invalidate() }  // the new runners must show up in the next list
        await removeStaleRecords(named: runnerNames)
        do {
            for name in runnerNames {
                let runner = try await client.createRunner(scope: scope, name: name, labels: runnerLabels)
                created.append(runner.uuid)
                guard let bundle = credentialBundle(runner: runner) else {
                    throw BitbucketError.missingOAuthClientSecret(name)
                }
                tokens[name] = bundle
            }
        } catch {
            // The instance is not going to start: its half-created runners
            // would otherwise sit UNREGISTERED on the forge for good.
            for uuid in created {
                await bestEffortAsync(account, "deleting runner \(uuid) of a failed registration") {
                    try await client.deleteRunner(scope: scope, uuid: uuid)
                }
            }
            throw error
        }
        return tokens
    }

    /// Runner records already carrying one of `names` (left by an earlier
    /// crashed run that reused the instance id) are deleted first: they would
    /// show as an offline runner of the new instance and mask its own state.
    private func removeStaleRecords(named names: [String]) async {
        await bestEffortAsync(account, "removing stale runner records") {
            let existing = try await client.listRunners(scope: scope)
            for runner in existing where names.contains(runner.name) {
                try await client.deleteRunner(scope: scope, uuid: runner.uuid)
            }
        }
    }

    /// The scope's runners. Steps do not name the runner that took them, so
    /// every runner reads busy while any step of the scope that this fleet
    /// serves is running, derived from a read of the steps now (not from
    /// whichever caller last looked). A token that cannot list runners (403
    /// or 404) reports none and is remembered; the engine then watches
    /// `unlistedRunnerActivity` instead of retrying the list to its deadline.
    func runners() async throws -> [ForgeRunner] {
        guard !runnerListSupport.isAbsent else { return [] }
        let runners: [BitbucketRunner]
        do {
            runners = try await runnerList.elements { try await client.listRunners(scope: scope) }
            runnerListSupport.markPresent()
        } catch ForgeAPIError.notFound, ForgeAPIError.forbidden {
            runnerListSupport.markAbsent()
            Log.info(name, "this token cannot list runners; watching running steps instead")
            return []
        }
        let busy = await scopeIsBusy()
        return runners.map { runner in
            ForgeRunner(id: runner.uuid, name: runner.name, busy: busy, online: runner.isOnline)
        }
    }

    /// With no runner list: the number of this fleet's steps running in the
    /// scope, which no runner can be matched to.
    func unlistedRunnerActivity(fresh: Bool) async throws -> Int? {
        guard runnerListSupport.isAbsent else { return nil }
        if fresh { jobList.invalidate() }
        return try await jobs().filter { $0.isRunning && $0.isSelfHosted }.count
    }

    /// Whether a step this fleet serves is running. A failed read counts as
    /// busy: an instance is never reclaimed on a guess.
    private func scopeIsBusy() async -> Bool {
        do {
            return try await jobs().contains { $0.isRunning && $0.isSelfHosted }
        } catch {
            if error is CancellationError { return true }
            Log.warn(name, "could not read running steps; treating runners as busy: \(error.localizedDescription)")
            return true
        }
    }

    func deleteRunner(id: String) async throws {
        defer { runnerList.invalidate() }
        try await client.deleteRunner(scope: scope, uuid: id)
    }

    /// Queued steps of the scope's active pipelines that run on a
    /// self-hosted runner and are waiting for one now. Attribution is by
    /// repository.
    func queuedJobs() async throws -> [ForgeJob] {
        try await jobs().filter { $0.isQueued && $0.isSelfHosted }.map {
            ForgeJob(name: $0.name, runnerName: nil, repository: $0.repository, labels: $0.runsOn)
        }
    }

    /// Running steps on self-hosted runners (they mark every runner of the
    /// scope busy — see `runners()`).
    func runningJobs() async throws -> [ForgeJob] {
        try await jobs().filter { $0.isRunning && $0.isSelfHosted }.map {
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

    /// The repositories to poll: the scope's one repo, or the workspace's
    /// most recently active ones (cached, see `repositoryList`).
    private func detailRepositories() async throws -> [String] {
        switch scope {
        case .workspace:
            return try await repositoryList.elements {
                Array(try await client.activeRepositories(scope: scope).prefix(20))
            }
        case .repository:
            return [scope.description]
        }
    }

    /// Steps of the scope's active pipelines with their `runs-on` resolved.
    /// The cache is asked first: the repository list and the pipelines are
    /// only read when the cached steps have expired, so a poll costs the
    /// requests of one read per interval however many callers ask.
    private func jobs() async throws -> [BitbucketJob] {
        try await jobList.elements {
            let repos = try await detailRepositories()
            let pipelines = try await client.activePipelines(scope: scope, repos: repos)
            var jobs: [BitbucketJob] = []
            for pipeline in pipelines {
                jobs.append(contentsOf: await resolveJobs(of: pipeline))
            }
            return jobs
        }
    }

    /// One pipeline's steps as jobs: `runs-on` from the pipeline file (the
    /// payload carries none), and whether each PENDING step is waiting for a
    /// runner now. Steps run in listed order, so a PENDING step behind a
    /// running one is a future step (it needs no runner yet), and a PAUSED or
    /// HALTED one is waiting for a person.
    func resolveJobs(of pipeline: BitbucketClient.ActivePipeline) async -> [BitbucketJob] {
        let file = await pipelinesFile(
            repository: pipeline.repository, commit: pipeline.pipeline.commit)
        var started = false
        var jobs: [BitbucketJob] = []
        for step in pipeline.steps {
            let runsOn: [String]
            if !step.runsOn.isEmpty {
                runsOn = step.runsOn
            } else if let file {
                runsOn = file.runsOn(stepNamed: step.name)
            } else {
                // No readable file (a failed read): counting the step errs towards one idle
                // runner that times out, rather than a pipeline waiting for ever.
                runsOn = ["self.hosted"]
            }
            let blocked = ["PAUSED", "HALTED"].contains(step.stageName ?? "")
            jobs.append(BitbucketJob(step: step, runsOn: runsOn, isReady: !started && !blocked))
            if step.isRunning { started = true }
        }
        return jobs
    }

    /// The pipeline file at `commit`: nil when the commit has none (every
    /// step is then a cloud step) and also when the read failed — the second
    /// case is distinguished by `Log`, and not cached.
    private func pipelinesFile(repository: String, commit: String?) async -> BitbucketPipelinesFile? {
        guard let commit else { return nil }
        let key = "\(repository)@\(commit)"
        if let cached = pipelinesFiles.lookup(key) { return cached }
        do {
            guard
                let data = try await client.sourceFile(
                    repository: repository, commit: commit, path: BitbucketPipelinesFile.fileName)
            else {
                pipelinesFiles.store(.empty, for: key)
                return .empty
            }
            let file = try BitbucketPipelinesFile(yaml: data)
            pipelinesFiles.store(file, for: key)
            return file
        } catch {
            if error is CancellationError { return nil }
            Log.warn(name, "could not read \(BitbucketPipelinesFile.fileName) of \(key): \(error.localizedDescription)")
            return nil
        }
    }
}
