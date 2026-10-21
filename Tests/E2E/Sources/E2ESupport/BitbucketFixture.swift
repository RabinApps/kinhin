import Foundation

/// A real Bitbucket Cloud repository, for a forge that cannot be self-hosted. Gated: it runs only when
/// `KINHIN_E2E_BITBUCKET_TOKEN` (a repository access token with the `repository:write`, `pipeline`, `pipeline:write`
/// and `runner:write` scopes) and `KINHIN_E2E_BITBUCKET_SCOPE` (`workspace/repo` of a **throwaway** repository that
/// already has a commit on its main branch) are set. `stop()` stops the pipelines it started and removes the pipeline
/// file it committed; Bitbucket keeps the finished pipelines' history.
///
/// Every job is a custom pipeline of one `bitbucket-pipelines.yml` that this fixture rewrites on each push and then
/// starts through the API, so jobs never wait on a push trigger and never read each other's file. A job proves it ran
/// by printing a `E2E-PROOF-<nonce>:` line, which the step log carries; Bitbucket has no issues to open.
///
/// Not verified live in the session that wrote it (no throwaway repository was available); the first run on a
/// machine with credentials is its acceptance test. `docs/forges/bitbucket.md` lists what that run must confirm.
public actor BitbucketFixture: ForgeFixture {
    public nonisolated let kind = ForgeKind.bitbucket
    public nonisolated let needsRunnerFloor = false

    public static var isConfigured: Bool {
        E2E.flag("KINHIN_E2E_BITBUCKET_TOKEN") != nil && E2E.flag("KINHIN_E2E_BITBUCKET_SCOPE") != nil
    }

    private static let apiBase = "https://api.bitbucket.org/2.0"
    private static let pipelineFile = "bitbucket-pipelines.yml"

    private let scope: String
    private let pat: String
    private var branch = "main"
    /// The custom pipelines committed so far, by name; the file holds all of them.
    private var customPipelines: [(name: String, yaml: String)] = []
    private var started: [String] = []

    public init() throws {
        guard let token = E2E.flag("KINHIN_E2E_BITBUCKET_TOKEN"), let scope = E2E.flag("KINHIN_E2E_BITBUCKET_SCOPE")
        else {
            throw E2EError.unavailable("set KINHIN_E2E_BITBUCKET_TOKEN and KINHIN_E2E_BITBUCKET_SCOPE (workspace/repo)")
        }
        guard scope.split(separator: "/").count == 2 else {
            throw E2EError.unavailable("KINHIN_E2E_BITBUCKET_SCOPE must be workspace/repo, got \(scope)")
        }
        pat = token
        self.scope = scope
    }

    public var account: FleetConfig.Account {
        FleetConfig.Account(name: "bitbucket", forge: "bitbucket", scope: scope)
    }

    public var token: String { pat }

    public func start() async throws {
        let repo = try await call("GET", "")
        guard repo.ok, let object = repo.json as? [String: Any] else {
            throw E2EError.failed("cannot read \(scope) with the given token: \(repo.status) \(repo.text)")
        }
        guard let main = (object["mainbranch"] as? [String: Any])?["name"] as? String else {
            throw E2EError.failed("\(scope) has no main branch; commit once to it first")
        }
        branch = main
        let enabled = try await call("PUT", "/pipelines_config", body: Http.encode(["enabled": true]))
        guard enabled.ok else {
            throw E2EError.failed("cannot enable Pipelines on \(scope): \(enabled.status) \(enabled.text)")
        }
    }

    public func stop() async throws {
        var failures: [String] = []
        var running: [String] = []
        for uuid in started {
            do {
                let pipeline = try await call("GET", "/pipelines/\(Self.encode(uuid))")
                let state = (pipeline.json as? [String: Any])?["state"] as? [String: Any]
                // A finished pipeline cannot be stopped and needs no stopping.
                if pipeline.ok, state?["name"] as? String == "COMPLETED" { continue }
                let response = try await call("POST", "/pipelines/\(Self.encode(uuid))/stopPipeline")
                guard response.ok else { throw E2EError.failed("\(response.status) \(response.text)") }
            } catch {
                running.append(uuid)
                failures.append("stopping pipeline \(uuid): \(error)")
            }
        }
        started = running
        if !customPipelines.isEmpty {
            do {
                // A form field named `files` deletes that path in the commit.
                let removed = try await commit(
                    form: ["files": Self.pipelineFile, "message": "e2e cleanup", "branch": branch])
                if removed.ok {
                    customPipelines.removeAll()
                } else {
                    failures.append("removing \(Self.pipelineFile): \(removed.status) \(removed.text)")
                }
            } catch {
                failures.append("removing \(Self.pipelineFile): \(error)")
            }
        }
        guard failures.isEmpty else {
            throw E2EError.failed("cleanup left Bitbucket state behind:\n" + failures.joined(separator: "\n"))
        }
    }

    /// `runs-on` labels: `self.hosted`, the platform label the runner advertises, and the pool's marker.
    public nonisolated func jobLabels(for runtime: RuntimeKind) -> [String] {
        let platform = runtime.guestKernel == "Linux" ? "linux.shell" : "macos"
        var labels = ["self.hosted", platform]
        if !labels.contains(runtime.runsOn) { labels.append(runtime.runsOn) }
        return labels
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
        let pipeline = "e2e-\(name)-\(nonce)"
        let runsOn = labels.map { "            - \($0)" }.joined(separator: "\n")
        let indented = ("export E2E_NONCE=\(nonce)\n" + script).split(
            separator: "\n", omittingEmptySubsequences: false
        ).map { "                  \($0)" }.joined(separator: "\n")
        let yaml = """
                \(pipeline):
                  - step:
                      name: e2e
                      runs-on:
            \(runsOn)
                      script:
                        - |
            \(indented)
            """
        customPipelines.append((pipeline, yaml))
        let file = "pipelines:\n  custom:\n" + customPipelines.map(\.yaml).joined(separator: "\n") + "\n"
        let pushed = try await commit(
            form: [Self.pipelineFile: file, "message": "e2e \(name)", "branch": branch])
        guard pushed.ok else {
            throw E2EError.failed("pushing the pipeline file failed: \(pushed.status) \(pushed.text)")
        }
        let run = try await call(
            "POST", "/pipelines/",
            body: Http.encode([
                "target": [
                    "type": "pipeline_ref_target", "ref_type": "branch", "ref_name": branch,
                    "selector": ["type": "custom", "pattern": pipeline],
                ]
            ]))
        guard run.ok, let uuid = (run.json as? [String: Any])?["uuid"] as? String else {
            throw E2EError.failed("starting the pipeline failed: \(run.status) \(run.text)")
        }
        started.append(uuid)
    }

    public func proof(nonce: String) async throws -> String? {
        let prefix = "E2E-PROOF-\(nonce): "
        for uuid in started {
            let steps = try await call("GET", "/pipelines/\(Self.encode(uuid))/steps/")
            guard let values = (steps.json as? [String: Any])?["values"] as? [[String: Any]] else { continue }
            for step in values {
                guard let stepUUID = step["uuid"] as? String else { continue }
                let log = try await call("GET", "/pipelines/\(Self.encode(uuid))/steps/\(Self.encode(stepUUID))/log")
                guard log.ok else { continue }
                // The command's own echo spells `$E2E_NONCE`, so only the printed line starts with the literal nonce.
                for line in log.text.split(whereSeparator: \.isNewline) where line.hasPrefix(prefix) {
                    return String(line.dropFirst(prefix.count))
                }
            }
        }
        return nil
    }

    /// One status per pipeline this fixture started, in Bitbucket's vocabulary mapped to the protocol's.
    public func runStatuses() async throws -> [String] {
        var statuses: [String] = []
        for uuid in started {
            let response = try await call("GET", "/pipelines/\(Self.encode(uuid))")
            guard let state = (response.json as? [String: Any])?["state"] as? [String: Any],
                let name = state["name"] as? String
            else { continue }
            let result = (state["result"] as? [String: Any])?["name"] as? String
            statuses.append(Self.status(state: name, result: result))
        }
        return statuses
    }

    static func status(state: String, result: String?) -> String {
        switch state {
        case "COMPLETED": return result == "SUCCESSFUL" ? "success" : "failure"
        case "IN_PROGRESS": return "running"
        default: return "waiting"
        }
    }

    public func registeredRunners() async throws -> [String] {
        let response = try await call("GET", "/pipelines-config/runners")
        guard let values = (response.json as? [String: Any])?["values"] as? [[String: Any]] else { return [] }
        return values.compactMap { $0["name"] as? String }
    }

    public func diagnostics() async -> String { "[bitbucket] \(scope), branch \(branch), pipelines \(started)" }

    /// `{uuid}` → `%7Buuid%7D`: Bitbucket's identifiers carry braces a URL path must encode.
    static func encode(_ uuid: String) -> String {
        uuid.replacingOccurrences(of: "{", with: "%7B").replacingOccurrences(of: "}", with: "%7D")
    }

    /// A commit through `POST …/src`, which takes a form: each field is a file path and its content, plus the
    /// `message` and `branch`.
    private func commit(form: [String: String]) async throws -> Http.Response {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = form.map { key, value in
            let name = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
            let content = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return "\(name)=\(content)"
        }.joined(separator: "&")
        return try await Http.request(
            "POST", "\(Self.apiBase)/repositories/\(scope)/src",
            headers: ["Authorization": "Bearer \(pat)", "Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8), timeout: 60)
    }

    private func call(_ method: String, _ path: String, body: Data? = nil) async throws -> Http.Response {
        try await Http.request(
            method, "\(Self.apiBase)/repositories/\(scope)\(path)",
            headers: ["Authorization": "Bearer \(pat)"], body: body, timeout: 60)
    }
}
