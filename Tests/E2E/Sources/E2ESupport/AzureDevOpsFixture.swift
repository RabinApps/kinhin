import Foundation

/// A real Azure DevOps project and self-hosted agent pool, for a forge that cannot be self-hosted. Gated: it runs
/// only when all of these are set, naming a **throwaway** project:
///
/// - `KINHIN_E2E_AZURE_TOKEN`: a PAT with Agent Pools (read and manage), Build (read and execute) and Code (read and
///   write) scopes, plus permission to create pipelines.
/// - `KINHIN_E2E_AZURE_ORG`: the organization name, or its URL (`https://dev.azure.com/<org>`, or a Server collection).
/// - `KINHIN_E2E_AZURE_PROJECT` and `KINHIN_E2E_AZURE_POOL`: the project and its self-hosted agent pool. The pool must
///   be authorized for all pipelines, or every run waits for a person to approve it.
///
/// `KINHIN_E2E_AZURE_REPO` names the Azure Repos repository that holds the pipeline files (default: the project's
/// own). `KINHIN_E2E_AZURE_FLOOR=1` runs the lane with `min_runners: 1`, for a pool that fails a job fast when no
/// agent advertises its demands (`docs/forges/azuredevops.md` lists this as the highest-impact unknown); without
/// it the lane runs with no floor, which is how to find out.
///
/// Each job is a YAML pipeline: `pushWorkflow` commits its file to the default branch, creates a pipeline for it and
/// starts a run. `stop()` cancels the runs, deletes the pipelines (and with them their runs) and removes the files.
/// A job proves it ran by printing an `E2E-PROOF-<nonce>:` line, which the run's log carries; Azure has no issues.
///
/// Not verified live in the session that wrote it (no throwaway project was available); the first run on a machine
/// with credentials is its acceptance test.
public actor AzureDevOpsFixture: ForgeFixture {
    public nonisolated let kind = ForgeKind.azuredevops
    public nonisolated let needsRunnerFloor: Bool

    public static var isConfigured: Bool {
        ["TOKEN", "ORG", "PROJECT", "POOL"].allSatisfy { E2E.flag("KINHIN_E2E_AZURE_\($0)") != nil }
    }

    private static let apiVersion = "api-version=7.0"
    private static let zeroObject = String(repeating: "0", count: 40)

    private let organizationURL: String
    private let project: String
    private let pool: String
    private let repositoryName: String
    private let pat: String
    private var repositoryID = ""
    private var branch = "refs/heads/main"
    private var poolID = 0
    private var pushedPaths: [String] = []
    private var pipelines: [Int] = []
    private var runs: [(pipeline: Int, run: Int)] = []

    public init() throws {
        guard Self.isConfigured, let token = E2E.flag("KINHIN_E2E_AZURE_TOKEN"),
            let org = E2E.flag("KINHIN_E2E_AZURE_ORG"), let project = E2E.flag("KINHIN_E2E_AZURE_PROJECT"),
            let pool = E2E.flag("KINHIN_E2E_AZURE_POOL")
        else {
            throw E2EError.unavailable(
                "set KINHIN_E2E_AZURE_TOKEN, KINHIN_E2E_AZURE_ORG, KINHIN_E2E_AZURE_PROJECT and KINHIN_E2E_AZURE_POOL")
        }
        pat = token
        organizationURL = Self.organizationURL(org)
        self.project = project
        self.pool = pool
        repositoryName = E2E.flag("KINHIN_E2E_AZURE_REPO") ?? project
        needsRunnerFloor = E2E.flag("KINHIN_E2E_AZURE_FLOOR") != nil
    }

    /// An organization name becomes its `dev.azure.com` URL; a URL (Services or a Server collection) is kept.
    static func organizationURL(_ org: String) -> String {
        var url = org.contains("://") ? org : "https://dev.azure.com/\(org)"
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    public var account: FleetConfig.Account {
        FleetConfig.Account(
            name: "azuredevops", forge: "azuredevops", scope: pool, instance: organizationURL, labels: ["kinhin"])
    }

    public var token: String { pat }

    public func start() async throws {
        let repo = try await call("GET", "/_apis/git/repositories/\(Self.segment(repositoryName))")
        guard repo.ok, let object = repo.json as? [String: Any], let id = object["id"] as? String else {
            throw E2EError.failed("cannot read the repository \(repositoryName): \(repo.status) \(repo.text)")
        }
        repositoryID = id
        // An empty repository has no default branch yet; the first push creates it.
        branch = object["defaultBranch"] as? String ?? "refs/heads/main"
        let pools = try await call(
            "GET", "/_apis/distributedtask/pools", at: organizationURL, query: "poolName=\(Self.query(pool))")
        guard let found = (pools.json as? [String: Any])?["value"] as? [[String: Any]],
            let id = found.first?["id"] as? Int
        else { throw E2EError.failed("no agent pool named \(pool): \(pools.status) \(pools.text)") }
        poolID = id
    }

    public func stop() async {
        for run in runs {
            _ = try? await call(
                "PATCH", "/_apis/build/builds/\(run.run)", body: Http.encode(["status": "cancelling"]))
        }
        for definition in pipelines { _ = try? await call("DELETE", "/_apis/build/definitions/\(definition)") }
        pipelines.removeAll()
        runs.removeAll()
        for path in pushedPaths {
            _ = try? await push(path: path, content: nil, comment: "e2e cleanup")
        }
        pushedPaths.removeAll()
    }

    /// Demands: the account's `kinhin` label, the pool's runtime marker as the capability the agent exports, and the OS
    /// for a Tart guest (which has no marker of its own).
    public nonisolated func jobLabels(for runtime: RuntimeKind) -> [String] {
        var demands = ["kinhin"]
        switch runtime {
        case .docker, .appleContainer, .host: demands.append(runtime.runsOn.replacingOccurrences(of: "-", with: "_"))
        case .tartMacOS: demands.append("Agent.OS -equals Darwin")
        case .tartLinux: demands.append("Agent.OS -equals Linux")
        }
        return demands
    }

    public nonisolated func proofScript(extra: String) -> String {
        """
        set -e
        \(extra)
        BODY="$(uname -s) $(hostname) $(pwd) ${E2E_EXTRA:-}"
        echo "E2E-PROOF-$E2E_NONCE: $BODY"
        """
    }

    public func pushWorkflow(name: String, labels: [String], nonce: String, script: String) async throws {
        let path = "/e2e/\(name)-\(nonce).yml"
        let demands = labels.map { "      - \($0)" }.joined(separator: "\n")
        let indented = script.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "      \($0)" }.joined(separator: "\n")
        let yaml = """
            trigger: none
            pool:
              name: \(pool)
              demands:
            \(demands)
            steps:
              - bash: |
            \(indented)
                displayName: e2e-\(name)
                env:
                  E2E_NONCE: "\(nonce)"
            """
        let pushed = try await push(path: path, content: yaml + "\n", comment: "e2e \(name)")
        guard pushed.ok else {
            throw E2EError.failed("pushing the pipeline file failed: \(pushed.status) \(pushed.text)")
        }
        pushedPaths.append(path)
        let created = try await call(
            "POST", "/_apis/pipelines",
            body: Http.encode([
                "name": "kinhin-e2e-\(name)-\(nonce)", "folder": "\\kinhin-e2e",
                "configuration": [
                    "type": "yaml", "path": path, "repository": ["id": repositoryID, "type": "azureReposGit"],
                ],
            ]))
        guard created.ok, let pipeline = (created.json as? [String: Any])?["id"] as? Int else {
            throw E2EError.failed("creating the pipeline failed: \(created.status) \(created.text)")
        }
        pipelines.append(pipeline)
        let run = try await call(
            "POST", "/_apis/pipelines/\(pipeline)/runs",
            body: Http.encode(["resources": ["repositories": ["self": ["refName": branch]]]]))
        guard run.ok, let runID = (run.json as? [String: Any])?["id"] as? Int else {
            throw E2EError.failed("starting the run failed: \(run.status) \(run.text)")
        }
        runs.append((pipeline, runID))
    }

    public func proof(nonce: String) async throws -> String? {
        let prefix = "E2E-PROOF-\(nonce): "
        for run in runs {
            let logs = try await call("GET", "/_apis/build/builds/\(run.run)/logs")
            guard let values = (logs.json as? [String: Any])?["value"] as? [[String: Any]] else { continue }
            for entry in values {
                guard let id = entry["id"] as? Int else { continue }
                let log = try await call("GET", "/_apis/build/builds/\(run.run)/logs/\(id)")
                guard log.ok else { continue }
                // The script's own echo spells `$E2E_NONCE`, so only the printed line carries the literal nonce.
                for line in log.text.split(whereSeparator: \.isNewline) {
                    if let range = line.range(of: prefix) { return String(line[range.upperBound...]) }
                }
            }
        }
        return nil
    }

    /// One status per run this fixture started, in Azure's vocabulary mapped to the protocol's.
    public func runStatuses() async throws -> [String] {
        var statuses: [String] = []
        for run in runs {
            let response = try await call("GET", "/_apis/pipelines/\(run.pipeline)/runs/\(run.run)")
            guard let object = response.json as? [String: Any], let state = object["state"] as? String else { continue }
            statuses.append(Self.status(state: state, result: object["result"] as? String))
        }
        return statuses
    }

    static func status(state: String, result: String?) -> String {
        switch state {
        case "completed": return result == "succeeded" ? "success" : "failure"
        case "inProgress", "canceling": return "running"
        default: return "waiting"
        }
    }

    public func registeredRunners() async throws -> [String] {
        let response = try await call(
            "GET", "/_apis/distributedtask/pools/\(poolID)/agents", at: organizationURL)
        guard response.ok, let values = (response.json as? [String: Any])?["value"] as? [[String: Any]] else {
            throw E2EError.failed("cannot list the agents of pool \(pool): \(response.status) \(response.text)")
        }
        return try values.map { agent in
            guard let name = agent["name"] as? String else {
                throw E2EError.failed("pool \(pool) lists an agent with no name: \(agent)")
            }
            return name
        }
    }

    public func diagnostics() async -> String {
        "[azuredevops] \(organizationURL) project \(project), pool \(pool), pipelines \(pipelines)"
    }

    /// Adds, or with `content: nil` deletes, one file on the default branch in a single commit.
    private func push(path: String, content: String?, comment: String) async throws -> Http.Response {
        let refs = try await call(
            "GET", "/_apis/git/repositories/\(repositoryID)/refs",
            query: "filter=\(Self.query(String(branch.dropFirst("refs/".count))))")
        let head =
            ((refs.json as? [String: Any])?["value"] as? [[String: Any]])?.first?["objectId"] as? String
            ?? Self.zeroObject
        var change: [String: Any] = ["changeType": content == nil ? "delete" : "add", "item": ["path": path]]
        if let content { change["newContent"] = ["content": content, "contentType": "rawtext"] }
        let body = try Http.encode([
            "refUpdates": [["name": branch, "oldObjectId": head]],
            "commits": [["comment": comment, "changes": [change]]],
        ])
        return try await call("POST", "/_apis/git/repositories/\(repositoryID)/pushes", body: body)
    }

    private static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private static func query(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// A call under the project (`/{project}/_apis/...`) unless `at` names another root, such as the organization's.
    private func call(
        _ method: String, _ path: String, at root: String? = nil, query: String? = nil, body: Data? = nil
    ) async throws -> Http.Response {
        let base = root ?? "\(organizationURL)/\(Self.segment(project))"
        let suffix = [query, Self.apiVersion].compactMap { $0 }.joined(separator: "&")
        let credentials = Data(":\(pat)".utf8).base64EncodedString()
        return try await Http.request(
            method, "\(base)\(path)?\(suffix)", headers: ["Authorization": "Basic \(credentials)"], body: body,
            timeout: 60)
    }
}
