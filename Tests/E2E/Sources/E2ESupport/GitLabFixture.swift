import Foundation

/// A throwaway GitLab CE server in a container (heavy: several GB, minutes to boot, about 4 GB of RAM), with the
/// root user, one project and one personal access token. Unlike Gitea, GitLab reports pending jobs without any
/// runner registered, so kinhin needs no floor.
public actor GitLabFixture: ForgeFixture {
    public nonisolated let kind = ForgeKind.gitlab
    public nonisolated let needsRunnerFloor = false

    private let image = E2E.flag("KINHIN_E2E_GITLAB_IMAGE") ?? "gitlab/gitlab-ce:17.11.7-ce.0"
    private let containerName = "ke2e-gitlab-\(E2E.randomID())"
    private let port: Int
    private let host: String
    private var adminToken = ""
    private var projectID = 0
    private var workflowFileExists = false

    public init() throws {
        guard let address = E2E.lanAddress else { throw E2EError.unavailable("no LAN address for containers to reach") }
        host = address
        port = try E2E.freePort()
    }

    private nonisolated var base: String { "http://\(host):\(port)" }

    public var account: FleetConfig.Account {
        FleetConfig.Account(
            name: "gitlab", forge: "gitlab", scope: "root/demo", instance: base, allowInsecureHTTP: true)
    }

    public var token: String { adminToken }

    public func start() async throws {
        let omnibus = [
            "external_url '\(base)'", "gitlab_rails['initial_root_password']='E2e-pass-\(E2E.randomID())-x'",
            "puma['worker_processes']=0", "sidekiq['concurrency']=4", "prometheus_monitoring['enable']=false",
            "gitlab_rails['usage_ping_enabled']=false",
            "gitlab_rails['gitlab_default_projects_features_container_registry']=false",
        ].joined(separator: "; ")
        let started = try await Shell.run(
            "docker",
            [
                "run", "-d", "--name", containerName, "--shm-size", "256m", "-p", "\(port):\(port)",
                "-e", "GITLAB_OMNIBUS_CONFIG=\(omnibus)", image,
            ], timeout: 1800)
        guard started.ok else { throw E2EError.failed("could not start \(image): \(started.output)") }
        try await Http.waitUntilUp("http://localhost:\(port)/users/sign_in", timeout: 900)

        let script =
            "t = User.find_by_username('root').personal_access_tokens.create!(scopes: [:api, :create_runner, :manage_runner, :read_api], name: 'e2e', expires_at: 30.days.from_now); t.set_token('glpat-e2e' + SecureRandom.hex(10)); t.save!; puts 'TOKEN=' + t.token"
        let minted = try await Shell.run(
            "docker", ["exec", containerName, "gitlab-rails", "runner", script], timeout: 600)
        guard minted.ok, let line = minted.stdout.split(separator: "\n").first(where: { $0.hasPrefix("TOKEN=") }) else {
            throw E2EError.failed("could not mint a personal access token: \(minted.output.suffix(1500))")
        }
        adminToken = String(line.dropFirst("TOKEN=".count))

        let project = try await call(
            "POST", "/projects",
            body: try Http.encode(["name": "demo", "initialize_with_readme": true, "visibility": "private"]))
        guard project.ok, let object = project.json as? [String: Any], let id = object["id"] as? Int else {
            throw E2EError.failed("project create failed: \(project.status) \(project.text)")
        }
        projectID = id
        let variable = try await call(
            "POST", "/projects/\(id)/variables", body: try Http.encode(["key": "E2E_TOKEN", "value": adminToken]))
        guard variable.ok else { throw E2EError.failed("CI variable failed: \(variable.status) \(variable.text)") }
    }

    public func stop() async {
        _ = try? await Shell.run("docker", ["rm", "-f", "-v", containerName], timeout: 120)
    }

    public nonisolated func proofScript(extra: String) -> String {
        """
        set -e
        \(extra)
        BODY="$(uname -s) $(hostname) ${E2E_EXTRA:-}"
        curl -sf -X POST "$E2E_API/issues" -H "PRIVATE-TOKEN: $E2E_TOKEN" \\
          -H "Content-Type: application/json" \\
          -d "{\\"title\\":\\"proof-$E2E_NONCE\\",\\"description\\":\\"$BODY\\"}"
        """
    }

    public func pushWorkflow(name: String, runsOn: String, nonce: String, script: String) async throws {
        let indented = script.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "      \($0)" }.joined(separator: "\n")
        // A pending job counts as demand only when its tags include all of the account's labels, which default to
        // the fleet's `self-hosted, linux, arm64`.
        let yaml = """
            prove:
              tags: [self-hosted, linux, arm64, \(runsOn)]
              variables:
                E2E_NONCE: "\(nonce)"
                E2E_API: "\(base)/api/v4/projects/\(projectID)"
              script:
                - |
            \(indented)
            """
        let method = workflowFileExists ? "PUT" : "POST"
        let response = try await call(
            method, "/projects/\(projectID)/repository/files/.gitlab-ci.yml",
            body: try Http.encode(["branch": "main", "content": yaml, "commit_message": "workflow \(name) \(nonce)"]))
        guard response.ok else {
            throw E2EError.failed("pushing the pipeline failed: \(response.status) \(response.text)")
        }
        workflowFileExists = true
    }

    public func proof(nonce: String) async throws -> String? {
        let response = try await call("GET", "/projects/\(projectID)/issues?search=proof-\(nonce)")
        guard let issues = response.json as? [[String: Any]] else { return nil }
        for issue in issues where (issue["title"] as? String) == "proof-\(nonce)" {
            return issue["description"] as? String ?? ""
        }
        return nil
    }

    public func runStatuses() async throws -> [String] {
        let response = try await call("GET", "/projects/\(projectID)/pipelines")
        guard let pipelines = response.json as? [[String: Any]] else { return [] }
        return pipelines.compactMap { ($0["status"] as? String).map { $0 == "failed" ? "failure" : $0 } }
    }

    public func registeredRunners() async throws -> [String] {
        let response = try await call("GET", "/projects/\(projectID)/runners")
        guard let runners = response.json as? [[String: Any]] else { return [] }
        return runners.compactMap { $0["description"] as? String }
    }

    public func diagnostics() async -> String {
        let logs = try? await Shell.run("docker", ["logs", "--tail", "40", containerName], timeout: 30)
        return "[gitlab logs]\n\(logs?.output ?? "unavailable")"
    }

    private func call(_ method: String, _ path: String, body: Data? = nil) async throws -> Http.Response {
        try await Http.request(
            method, "http://localhost:\(port)/api/v4" + path, headers: ["PRIVATE-TOKEN": adminToken], body: body,
            timeout: 60)
    }
}
