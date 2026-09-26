import Foundation

// GitHubClient — workflow runs and their jobs. Reads the org-wide runs
// endpoint when the token can, else fans out per repository (fine-grained
// tokens), bounded per poll.
extension GitHubClient {
    /// The scope's runs with the given status, through whichever endpoint the
    /// token can read, capped per poll like the jobs fan-out.
    func runs(status: String) async throws -> [RunRef] {
        var all = try await fetchRuns(status: status)
        if all.count > maxRunsPerPoll {
            all = Array(all.prefix(maxRunsPerPoll))
        }
        return all
    }

    /// All runs in the scope with the given status, following pagination.
    ///
    /// GitHub grants fine-grained tokens runs access only through the
    /// *repository* Actions permission; no fine-grained organization
    /// permission unlocks `/orgs/{org}/actions/runs`, so org scope gets 404s
    /// there even from tokens that manage runners fine. When that happens we
    /// fall back to reading each repository's runs (see `runsFromRepos`); the
    /// sticky flag skips the failing org call on later polls. Classic tokens
    /// (`repo` scope) never need the fallback.
    func fetchRuns(status: String) async throws -> [RunRef] {
        guard credentials.isOrgScope else {
            return try await pagedRuns(path: "\(credentials.actionsBase)/runs", status: status, repository: nil)
        }
        if runsMode.viaRepos {
            return try await runsFromRepos(status: status)
        }
        do {
            return try await pagedRuns(path: "\(credentials.actionsBase)/runs", status: status, repository: nil)
        } catch GitHubError.notFound {
            runsMode.setViaRepos()
            Log.warn(
                "engine",
                "org runs endpoint not readable for '\(credentials.scope)' — fine-grained tokens cannot read "
                    + "/orgs/{org}/actions/runs; falling back to per-repository reads (a classic token with "
                    + "the repo scope avoids this)")
        }
        return try await runsFromRepos(status: status)
    }

    /// One paginated runs fetch against a single endpoint. `repository`
    /// attaches attribution for per-repository fallback reads.
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

    /// Reads runs repo-by-repo (fine-grained-token fallback), attributing
    /// each run to the repository it was read from. Repos the token cannot
    /// see (404) are skipped: one unreadable repository must not fail the
    /// whole queue read, and it contributes no jobs by definition.
    func runsFromRepos(status: String) async throws -> [RunRef] {
        let repos = try await listScopeRepositories()
        var runs: [RunRef] = []
        var readableRepos = 0
        for repo in repos.prefix(maxReposPerPoll) {
            do {
                runs.append(
                    contentsOf: try await pagedRuns(
                        path: "/repos/\(repo)/actions/runs", status: status, repository: repo))
                readableRepos += 1
            } catch GitHubError.notFound {
                continue  // token has no Actions read on this repository
            }
        }
        // An empty result must not hide a broken token: when the scope lists
        // repositories but not one of them exposes runs, the autoscaler would
        // silently see an empty queue forever. Fail loudly instead.
        if readableRepos == 0, !repos.isEmpty {
            throw GitHubError.notFound("/repos/\(credentials.owner)/*/actions/runs")
        }
        return runs
    }

    /// Repositories to poll in fallback mode: the org's repos, or — when
    /// even that 404s (the org repo list needs Members read) — every repo
    /// the token can see, filtered down to the scope's org.
    func listScopeRepositories() async throws -> [String] {
        do {
            return try await pagedRepoNames(path: "/orgs/\(credentials.scope)/repos")
        } catch GitHubError.notFound {
            let all = try await pagedRepoNames(path: "/user/repos?affiliation=owner,collaborator,organization_member")
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

    /// All jobs of one workflow run. In per-repository fallback mode the
    /// run's scoped repository supplies the repo-scoped jobs path (the
    /// org-scope path 404s for fine-grained tokens).
    func fetchJobs(runID: Int, repository: String?) async throws -> [GHJob] {
        let jobsPath =
            repository.map { "/repos/\($0)/actions/runs/\(runID)/jobs" }
            ?? "\(credentials.actionsBase)/runs/\(runID)/jobs"
        let req = try request(method: "GET", path: "\(jobsPath)?per_page=100")
        let (data, _) = try await send(req)
        do {
            return try JSONDecoder().decode(JobsResponse.self, from: data).jobs
        } catch {
            throw GitHubError.decoding("jobs: \(error.localizedDescription)")
        }
    }

    /// One workflow run plus the repository it was read from (nil in org
    /// mode, where the run payload itself carries the repository).
    struct RunRef: Codable {
        let id: Int
        let repository: RepoSummary?
        /// Repository the runs endpoint was scoped to (fallback reads).
        let scopedRepository: String?

        init(summary: RunSummary, repository: String?) {
            self.id = summary.id
            self.repository = summary.repository
            self.scopedRepository = repository
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
    }

    struct JobsResponse: Codable {
        let jobs: [GHJob]
    }
}
