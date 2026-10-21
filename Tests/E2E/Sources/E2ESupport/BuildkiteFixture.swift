import Foundation

/// A real Buildkite organization and cluster, for a forge that cannot be self-hosted. Gated: it runs only when
/// `KINHIN_E2E_BUILDKITE_TOKEN` (a REST API token with `read_agents`, `write_agents`, `read_builds`, `read_clusters`,
/// `write_clusters`, `write_pipelines` and `write_builds`) and `KINHIN_E2E_BUILDKITE_SCOPE` (`org/cluster` of a
/// **throwaway** organization whose cluster already has the `kinhin` queue) are set. It leaves nothing behind:
/// `stop()` deletes the pipelines it created, which removes their builds.
///
/// A job proves it ran by writing build meta-data (`buildkite-agent meta-data set proof-<nonce>`), which the build
/// carries as `meta_data`; Buildkite has no issues to open. The job skips the git checkout, so the pipeline's
/// repository is never cloned; set `KINHIN_E2E_BUILDKITE_REPO` to override the placeholder it names.
///
/// Not verified live in the session that wrote it (no throwaway organization was available); the first run on a
/// machine with credentials is its acceptance test. `docs/forges/buildkite.md` lists what that run must confirm.
public actor BuildkiteFixture: ForgeFixture {
    public nonisolated let kind = ForgeKind.buildkite
    public nonisolated let needsRunnerFloor = false

    public static var isConfigured: Bool {
        E2E.flag("KINHIN_E2E_BUILDKITE_TOKEN") != nil && E2E.flag("KINHIN_E2E_BUILDKITE_SCOPE") != nil
    }

    private static let apiBase = "https://api.buildkite.com/v2"
    /// Never cloned (the step skips checkout), but a pipeline must name a repository.
    private static let placeholderRepository = "https://github.com/RabinApps/kinhin.git"
    private static let queue = "kinhin"

    private let scope: String
    private let pat: String
    private let repository: String
    private var clusterID: String?
    private var pipelines: [String] = []
    private var builds: [(pipeline: String, number: Int)] = []

    public init() throws {
        guard let token = E2E.flag("KINHIN_E2E_BUILDKITE_TOKEN"), let scope = E2E.flag("KINHIN_E2E_BUILDKITE_SCOPE")
        else {
            throw E2EError.unavailable("set KINHIN_E2E_BUILDKITE_TOKEN and KINHIN_E2E_BUILDKITE_SCOPE (org/cluster)")
        }
        guard scope.split(separator: "/", maxSplits: 1).count == 2 else {
            throw E2EError.unavailable("KINHIN_E2E_BUILDKITE_SCOPE must be org/cluster, got \(scope)")
        }
        pat = token
        self.scope = scope
        repository = E2E.flag("KINHIN_E2E_BUILDKITE_REPO") ?? Self.placeholderRepository
    }

    private var organization: String { String(scope.split(separator: "/", maxSplits: 1)[0]) }
    private var clusterName: String { String(scope.split(separator: "/", maxSplits: 1)[1]) }

    public var account: FleetConfig.Account {
        FleetConfig.Account(name: "buildkite", forge: "buildkite", scope: scope, labels: ["queue=\(Self.queue)"])
    }

    public var token: String { pat }

    public func start() async throws {
        let response = try await call("GET", "/clusters")
        guard response.ok, let clusters = response.json as? [[String: Any]] else {
            throw E2EError.failed("cannot list the clusters of \(organization): \(response.status) \(response.text)")
        }
        let match = clusters.first {
            ($0["id"] as? String) == clusterName
                || ($0["name"] as? String)?.caseInsensitiveCompare(clusterName) == .orderedSame
        }
        guard let id = match?["id"] as? String else {
            throw E2EError.failed("\(organization) has no cluster \(clusterName)")
        }
        clusterID = id
        let queues = try await call("GET", "/clusters/\(id)/queues")
        let keys = (queues.json as? [[String: Any]])?.compactMap { $0["key"] as? String } ?? []
        guard keys.contains(Self.queue) else {
            throw E2EError.failed("cluster \(clusterName) needs a queue with the key \(Self.queue); it has \(keys)")
        }
    }

    public func stop() async throws {
        var failures: [String] = []
        var remaining: [String] = []
        for slug in pipelines {
            do {
                let response = try await call("DELETE", "/pipelines/\(slug)")
                // A pipeline that is already gone needs no deleting.
                guard response.ok || response.status == 404 else {
                    throw E2EError.failed("\(response.status) \(response.text)")
                }
            } catch {
                remaining.append(slug)
                failures.append("deleting pipeline \(slug): \(error)")
            }
        }
        pipelines = remaining
        builds = builds.filter { remaining.contains($0.pipeline) }
        guard failures.isEmpty else {
            throw E2EError.failed("cleanup left Buildkite pipelines behind:\n" + failures.joined(separator: "\n"))
        }
    }

    /// Agent query rules, `key=value`: the queue the account's agents join, plus the pool marker as a tag.
    public nonisolated func jobLabels(for runtime: RuntimeKind) -> [String] {
        var rules = ["queue=\(Self.queue)"]
        switch runtime {
        case .docker, .appleContainer, .host:
            rules.append("kinhin-runtime=\(runtime.runsOn.dropFirst("kinhin-".count))")
        // Tart pools have no Buildkite tag form, so their jobs go to the default pool by queue alone.
        case .tartMacOS, .tartLinux: break
        }
        return rules
    }

    public nonisolated func proofScript(extra: String) -> String {
        """
        set -e
        \(extra)
        BODY="$(uname -s) $(hostname) $(pwd) ${E2E_EXTRA:-}"
        buildkite-agent meta-data set "proof-$E2E_NONCE" "$BODY"
        """
    }

    public func pushWorkflow(name: String, labels: [String], nonce: String, script: String) async throws {
        guard let clusterID else { throw E2EError.failed("start() has not run") }
        let agents = labels.compactMap { rule -> String? in
            guard let equals = rule.firstIndex(of: "=") else { return nil }
            return "        \(rule[..<equals]): \"\(rule[rule.index(after: equals)...])\""
        }.joined(separator: "\n")
        let indented = script.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "        \($0)" }.joined(separator: "\n")
        let steps = """
            steps:
              - label: e2e-\(name)
                skip_checkout: true
                env:
                  E2E_NONCE: "\(nonce)"
                agents:
            \(agents)
                command: |
            \(indented)
            """
        let created = try await call(
            "POST", "/pipelines",
            body: Http.encode([
                "name": "kinhin-e2e-\(name)-\(nonce)", "repository": repository, "cluster_id": clusterID,
                "configuration": steps,
            ]))
        guard created.ok, let slug = (created.json as? [String: Any])?["slug"] as? String else {
            throw E2EError.failed("creating the pipeline failed: \(created.status) \(created.text)")
        }
        pipelines.append(slug)
        let build = try await call(
            "POST", "/pipelines/\(slug)/builds",
            body: Http.encode(["commit": "HEAD", "branch": "main", "message": "e2e \(name) \(nonce)"]))
        guard build.ok, let number = (build.json as? [String: Any])?["number"] as? Int else {
            throw E2EError.failed("starting the build failed: \(build.status) \(build.text)")
        }
        builds.append((slug, number))
    }

    public func proof(nonce: String) async throws -> String? {
        for build in builds {
            let response = try await call("GET", "/pipelines/\(build.pipeline)/builds/\(build.number)")
            guard let object = response.json as? [String: Any], let meta = object["meta_data"] as? [String: Any],
                let value = meta["proof-\(nonce)"] as? String
            else { continue }
            return value
        }
        return nil
    }

    /// One status per build this fixture started, in Buildkite's vocabulary mapped to the protocol's.
    public func runStatuses() async throws -> [String] {
        var statuses: [String] = []
        for build in builds {
            let response = try await call("GET", "/pipelines/\(build.pipeline)/builds/\(build.number)")
            guard let object = response.json as? [String: Any], let state = object["state"] as? String else { continue }
            statuses.append(Self.status(of: state))
        }
        return statuses
    }

    static func status(of state: String) -> String {
        switch state {
        case "passed": return "success"
        case "failed", "failing", "canceled", "canceling", "skipped", "not_run": return "failure"
        case "running": return "running"
        default: return "waiting"
        }
    }

    public func registeredRunners() async throws -> [String] {
        let response = try await call("GET", "/agents")
        guard let agents = response.json as? [[String: Any]] else { return [] }
        return agents.compactMap { $0["name"] as? String }
    }

    public func diagnostics() async -> String { "[buildkite] \(scope), pipelines \(pipelines)" }

    private func call(_ method: String, _ path: String, body: Data? = nil) async throws -> Http.Response {
        try await Http.request(
            method, "\(Self.apiBase)/organizations/\(organization)\(path)",
            headers: ["Authorization": "Bearer \(pat)"], body: body, timeout: 60)
    }
}
