import Foundation

// GitHubClient — workflow runs and their jobs. Reads only documented
// endpoints: org scope fans out per repository, bounded per poll.
extension GitHubClient {
    /// The scope's runs with the given status, capped per poll like the jobs
    /// fan-out (`maxRunsPerPoll`).
    func runs(status: String) async throws -> [RunRef] {
        var all = try await fetchRuns(status: status)
        if all.count > maxRunsPerPoll {
            all = Array(all.prefix(maxRunsPerPoll))
        }
        return all
    }

    /// All runs in the scope with the given status, following pagination.
    ///
    /// GitHub documents no org-wide runs endpoint, so org scope reads
    /// repository by repository through `GET /repos/{repo}/actions/runs`
    /// (see `runsFromRepos`), bounded by `maxReposPerPoll` repositories and
    /// `maxRunsPerPoll` runs per poll. Each run is attributed
    /// (`attributedRepository`) to the repository it was read from.
    func fetchRuns(status: String) async throws -> [RunRef] {
        guard credentials.isOrgScope else {
            return try await pagedRuns(path: "\(credentials.actionsBase)/runs", status: status, repository: nil)
        }
        return try await runsFromRepos(status: status)
    }

    /// One paginated runs fetch against a single endpoint. `repository`
    /// attaches attribution for per-repository reads.
    func pagedRuns(path: String, status: String, repository: String?) async throws -> [RunRef] {
        var runs: [RunRef] = []
        var page = 1
        while true {
            let req = try request(method: "GET", path: "\(path)?status=\(status)&per_page=100&page=\(page)")
            let (data, _) = try await send(req)
            let decoded: RunsResponse
            do {
                decoded = try JSONDecoder().decode(RunsResponse.self, from: data)
            } catch {
                throw GitHubError.decoding("runs: \(error.localizedDescription)")
            }
            runs.append(contentsOf: decoded.workflow_runs.map { RunRef(summary: $0, repository: repository) })
            let totalPages = (decoded.total_count + 99) / 100
            if page >= max(totalPages, 1) || decoded.workflow_runs.isEmpty { break }
            page += 1
        }
        return runs
    }

    /// Reads runs repo-by-repo (org scope), attributing
    /// each run to the repository it was read from. Repos the token cannot
    /// see (404) are skipped: one unreadable repository must not fail the
    /// whole queue read, and it contributes no jobs by definition.
    func runsFromRepos(status: String) async throws -> [RunRef] {
        let repos = try await listScopeRepositories()
        // Concurrent per-repo reads; `nil` marks a repository the token
        // cannot read. Results keep the repos' (most recently pushed) order.
        let perRepo = try await boundedMap(Array(repos.prefix(maxReposPerPoll)), limit: maxConcurrentReads) {
            repo -> [RunRef]? in
            do {
                return try await self.pagedRuns(
                    path: "/repos/\(repo)/actions/runs", status: status, repository: repo)
            } catch GitHubError.notFound {
                return nil  // token has no Actions read on this repository
            }
        }
        let runs = perRepo.compactMap { $0 }.flatMap { $0 }
        let readableRepos = perRepo.compactMap { $0 }.count
        // An empty result must not hide a broken token: when the scope lists
        // repositories but not one of them exposes runs, the autoscaler would
        // silently see an empty queue forever. Fail loudly instead.
        if readableRepos == 0, !repos.isEmpty {
            throw GitHubError.notFound("/repos/\(credentials.owner)/*/actions/runs")
        }
        return runs
    }

    /// Repositories to poll in org scope, most recently pushed first so the
    /// per-poll cap (`maxReposPerPoll`) keeps the repos that actually have
    /// work instead of cutting off alphabetically-late ones: the org's repos, or — when
    /// even that 404s (the org repo list needs Members read) — every repo
    /// the token can see, filtered down to the scope's org.
    func listScopeRepositories() async throws -> [String] {
        try await scopeRepoCache.elements(fetch: fetchScopeRepositories)
    }

    func fetchScopeRepositories() async throws -> [String] {
        do {
            return try await pagedRepoNames(path: "/orgs/\(credentials.scope)/repos?sort=pushed&direction=desc")
        } catch GitHubError.notFound {
            let all = try await pagedRepoNames(
                path: "/user/repos?affiliation=owner,collaborator,organization_member&sort=pushed&direction=desc")
            let prefix = "\(credentials.owner)/"
            return all.filter { $0.hasPrefix(prefix) }
        }
    }

    /// Names ("owner/repo") from a paginated repositories list.
    func pagedRepoNames(path: String) async throws -> [String] {
        var names: [String] = []
        var page = 1
        while true {
            let separator = path.contains("?") ? "&" : "?"
            let req = try request(method: "GET", path: "\(path)\(separator)per_page=100&page=\(page)")
            let (data, _) = try await send(req)
            struct RepoName: Decodable { let full_name: String }
            let batch: [RepoName]
            do {
                batch = try JSONDecoder().decode([RepoName].self, from: data)
            } catch {
                throw GitHubError.decoding("repos: \(error.localizedDescription)")
            }
            names.append(contentsOf: batch.map(\.full_name))
            if batch.count < 100 { break }
            page += 1
        }
        return names
    }

    /// All jobs of one workflow run, following pagination (a large matrix has more than one page). In org scope the
    /// run's scoped repository supplies the repo-scoped jobs path.
    func fetchJobs(runID: Int, repository: String?) async throws -> [GHJob] {
        let jobsPath =
            repository.map { "/repos/\($0)/actions/runs/\(runID)/jobs" }
            ?? "\(credentials.actionsBase)/runs/\(runID)/jobs"
        var jobs: [GHJob] = []
        var seen = Set<Int>()
        for page in 1...Self.maxJobPages {
            let req = try request(method: "GET", path: "\(jobsPath)?per_page=\(Self.jobsPerPage)&page=\(page)")
            let (data, _) = try await send(req)
            let batch: [GHJob]
            do {
                batch = try JSONDecoder().decode(JobsResponse.self, from: data).jobs
            } catch {
                throw GitHubError.decoding("jobs: \(error.localizedDescription)")
            }
            // Pages shift while jobs change state: a job can show up on two of them.
            jobs.append(contentsOf: batch.filter { seen.insert($0.id).inserted })
            if batch.count < Self.jobsPerPage { break }
        }
        return jobs
    }

    static var jobsPerPage: Int { 100 }
    /// Bounds a runaway run: 1,000 jobs is past GitHub's own matrix limit.
    static var maxJobPages: Int { 10 }

    /// The run `runnerName`'s in-progress job belongs to, with all of the
    /// run's jobs and their steps. The jobs payload already carries
    /// `steps[]`, so this costs no request beyond the runs/jobs reads the
    /// running-attribution poll makes.
    public func pipelineDetail(runnerName: String) async throws -> PipelineDetail? {
        let runs = try await runs(status: "in_progress")
        // Look at a few runs at a time, in order: the first run holding the
        // runner wins (as before) without fetching every run's jobs.
        var offset = 0
        while offset < runs.count {
            let chunk = Array(runs[offset..<min(offset + maxConcurrentReads, runs.count)])
            offset += chunk.count
            let jobLists = try await boundedMap(chunk, limit: maxConcurrentReads) { run in
                try await self.fetchJobs(runID: run.id, repository: run.scopedRepository)
            }
            for (run, jobs) in zip(chunk, jobLists)
            where jobs.contains(where: { $0.runnerName == runnerName && $0.status == "in_progress" }) {
                let repository = run.attributedRepository ?? (credentials.isOrgScope ? nil : credentials.scope)
                return Self.detail(jobs: jobs, run: run, runnerName: runnerName, repository: repository)
            }
        }
        return nil
    }

    static func detail(jobs: [GHJob], run: RunRef, runnerName: String, repository: String?) -> PipelineDetail {
        let mapped = jobs.map { job -> PipelineJob in
            let steps = (job.steps ?? []).sorted { ($0.number ?? 0) < ($1.number ?? 0) }.map {
                PipelineStep(
                    name: $0.name, state: PipelineParsing.state(status: $0.status, conclusion: $0.conclusion),
                    startedAt: PipelineParsing.date($0.startedAt), finishedAt: PipelineParsing.date($0.completedAt))
            }
            return PipelineJob(
                id: String(job.id), name: job.name,
                state: PipelineParsing.state(status: job.status, conclusion: job.conclusion),
                startedAt: PipelineParsing.date(job.startedAt), finishedAt: PipelineParsing.date(job.completedAt),
                url: job.htmlURL, steps: steps,
                isCurrent: job.runnerName == runnerName, logRef: repository.map { "\($0)|\(job.id)" })
        }
        let first = jobs.first
        return PipelineDetail(
            forge: .github, title: first?.workflowName ?? first?.name ?? "Workflow run",
            repository: run.attributedRepository, ref: run.ref, sha: run.sha, url: first?.htmlURL,
            state: PipelineDetail.aggregate(mapped.map(\.state)),
            startedAt: mapped.compactMap(\.startedAt).min(), jobs: mapped, granularity: .step)
    }

    /// One job's log so far. The endpoint answers with a redirect to a signed
    /// URL on another host, which the session refuses to follow with
    /// credentials; the signed URL is fetched by hand, without them.
    public func jobLog(repository: String, jobID: Int) async throws -> String? {
        let segments = repository.split(separator: "/")
        guard segments.count == 2, segments.allSatisfy(Self.isValidScopeSegment) else {
            throw GitHubError.http(0, "invalid repository \(repository)")
        }
        let req = try request(method: "GET", path: "/repos/\(repository)/actions/jobs/\(jobID)/logs")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.http(0, "non-HTTP response") }
        switch http.statusCode {
        case 200: return String(decoding: data, as: UTF8.self)
        case 301, 302, 303, 307, 308:
            guard let location = http.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)),
                location.scheme?.lowercased() == "https"
            else { throw GitHubError.http(http.statusCode, "log redirect without an https location") }
            var signed = URLRequest(url: location)
            signed.setValue(ForgeHTTP.userAgent, forHTTPHeaderField: "User-Agent")
            // Log downloads are the one place a cross-host hop is allowed:
            // github.com and GHES both redirect to their blob storage on
            // another host, and the signed URL is fetched by hand with no
            // Authorization header, so no credential rides along. Every other
            // endpoint still goes through the shared session, whose
            // RedirectGuard refuses cross-host redirects.
            let (body, bodyResponse) = try await session.data(for: signed)
            switch (bodyResponse as? HTTPURLResponse)?.statusCode {
            case 200: break
            case 404, 410: return nil  // not available yet, or expired (e.g. a live job whose log blob is not written)
            case .some(let code): throw GitHubError.http(code, "log download failed")
            case .none: throw GitHubError.http(0, "non-HTTP response on log download")
            }
            return String(decoding: body, as: UTF8.self)
        case 401: throw GitHubError.unauthorized
        case 404, 410: return nil  // not available yet, or expired
        default: throw GitHubError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    /// One workflow run plus the repository it was read from (nil in org
    /// mode, where the run payload itself carries the repository).
    struct RunRef: Codable {
        let id: Int
        let repository: RepoSummary?
        /// Repository the runs endpoint was scoped to (fallback reads).
        let scopedRepository: String?
        let ref: String?
        let sha: String?
        let isFork: Bool
        /// Both the head and base repository were in the payload.
        let forkKnown: Bool

        init(summary: RunSummary, repository: String?) {
            self.id = summary.id
            self.repository = summary.repository
            self.scopedRepository = repository
            self.ref = summary.head_branch
            self.sha = summary.head_sha
            // A pull request from a fork runs with the fork as head repository.
            let base = summary.repository?.full_name ?? repository
            if let head = summary.head_repository?.full_name, let base {
                self.isFork = head.caseInsensitiveCompare(base) != .orderedSame
                self.forkKnown = true
            } else {
                self.isFork = false
                self.forkKnown = false
            }
        }

        /// What jobs of this run should be attributed to: the run payload's
        /// repository when present, else the repository the fallback read
        /// the run from.
        var attributedRepository: String? { repository?.full_name ?? scopedRepository }
    }

    /// Nested repo object inside workflow-run payloads (distinct from the
    /// public RepoRef picker model).
    struct RepoSummary: Codable {
        let full_name: String
    }

    struct RunsResponse: Codable {
        let total_count: Int
        let workflow_runs: [RunSummary]
    }

    struct RunSummary: Codable {
        let id: Int
        let repository: RepoSummary?
        let head_branch: String?
        let head_sha: String?
        let head_repository: RepoSummary?
    }

    struct JobsResponse: Codable {
        let jobs: [GHJob]
    }
}
