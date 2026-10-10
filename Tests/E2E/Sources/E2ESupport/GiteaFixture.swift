import Foundation

/// A throwaway Gitea or Forgejo server in a container, with one admin, one repository and one access token.
///
/// Both forges share this fixture: they are wire-compatible and differ only in image, binary name and the prefix of
/// their environment-variable configuration. Pinned image versions keep runs reproducible; bump them on purpose.
public actor GiteaFixture: ForgeFixture {
    public nonisolated let kind: ForgeKind
    /// Gitea before 1.25 lists no waiting task until a runner is registered, so kinhin sees no queued work for it
    /// and needs the floor (`min_runners: 1`) to keep one runner alive. Gitea 1.25+ (`/actions/jobs?status=queued`)
    /// and Forgejo 11+ (`/actions/runners/jobs?labels=`) show queued jobs before any runner exists.
    public nonisolated let needsRunnerFloor: Bool

    private let image: String
    private let binary: String
    private let envPrefix: String
    private let containerName: String
    private let port: Int
    private let host: String
    private let owner = "e2e"
    private let repo = "demo"
    private var adminToken = ""

    /// The Gitea image for lanes that cannot use a runner floor (host mode: the floor lands in the default pool).
    public static let floorFreeGiteaImage = "gitea/gitea:1.26"

    /// `image` overrides the pinned (or `KINHIN_E2E_*_IMAGE`) default.
    public init(kind: ForgeKind, image: String? = nil) throws {
        guard kind == .gitea || kind == .forgejo else { throw E2EError.failed("\(kind) is not a Gitea-family forge") }
        guard let address = E2E.lanAddress else { throw E2EError.unavailable("no LAN address for containers to reach") }
        self.kind = kind
        host = address
        port = try E2E.freePort()
        containerName = "ke2e-\(kind.rawValue)-\(E2E.randomID())"
        if kind == .gitea {
            self.image = image ?? E2E.flag("KINHIN_E2E_GITEA_IMAGE") ?? "gitea/gitea:1.24"
            binary = "gitea"
            envPrefix = "GITEA"
        } else {
            self.image = image ?? E2E.flag("KINHIN_E2E_FORGEJO_IMAGE") ?? "codeberg.org/forgejo/forgejo:11"
            binary = "forgejo"
            envPrefix = "FORGEJO"
        }
        needsRunnerFloor = GiteaFixture.needsFloor(kind: kind, image: self.image)
    }

    /// True for a Gitea older than 1.25 (or an image whose version cannot be read, to stay on the safe side).
    static func needsFloor(kind: ForgeKind, image: String) -> Bool {
        guard kind == .gitea else { return false }
        let tag = image.split(separator: ":").last.map(String.init) ?? ""
        let parts = tag.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2, parts[0] == 1 else { return tag != "latest" ? true : false }
        return parts[1] < 25
    }

    private nonisolated var base: String { "http://\(host):\(port)" }
    private nonisolated var api: String { "http://localhost:\(port)/api/v1" }

    public var account: FleetConfig.Account {
        FleetConfig.Account(
            name: kind.rawValue, forge: kind.rawValue, scope: "\(owner)/\(repo)", instance: base,
            allowInsecureHTTP: true)
    }

    public var token: String { adminToken }

    public func start() async throws {
        var args = [
            "run", "-d", "--name", containerName, "-p", "\(port):3000",
            "-e", "\(envPrefix)__security__INSTALL_LOCK=true",
            "-e", "\(envPrefix)__server__ROOT_URL=\(base)/",
            "-e", "\(envPrefix)__server__DOMAIN=\(host)",
            "-e", "\(envPrefix)__actions__ENABLED=true",
            "-e", "\(envPrefix)__database__DB_TYPE=sqlite3",
            "-e", "\(envPrefix)__service__DISABLE_REGISTRATION=true",
        ]
        args.append(image)
        let started = try await Shell.run("docker", args, timeout: 600)
        guard started.ok else { throw E2EError.failed("could not start \(image): \(started.output)") }
        try await Http.waitUntilUp("http://localhost:\(port)/api/healthz", timeout: 180)

        // uid 1000 is the `git` user in both images; named users are avoided on purpose.
        let created = try await Shell.run(
            "docker",
            [
                "exec", "-u", "1000", containerName, binary, "admin", "user", "create", "--admin", "--username", owner,
                "--password", "E2e-pass-\(E2E.randomID())", "--email", "e2e@example.com",
                "--must-change-password=false",
            ], timeout: 120)
        guard created.ok else { throw E2EError.failed("admin user create failed: \(created.output)") }
        let minted = try await Shell.run(
            "docker",
            [
                "exec", "-u", "1000", containerName, binary, "admin", "user", "generate-access-token", "--username",
                owner, "--scopes", "all", "--raw",
            ], timeout: 120)
        guard minted.ok, let last = minted.trimmedStdout.split(separator: "\n").last, !last.isEmpty else {
            throw E2EError.failed("access token failed: \(minted.output)")
        }
        adminToken = String(last)

        let repoCreated = try await call(
            "POST", "/user/repos", body: try Http.encode(["name": repo, "auto_init": true, "default_branch": "main"]))
        guard repoCreated.ok else { throw E2EError.failed("repo create failed: \(repoCreated.text)") }
        // The job proves itself by opening an issue, which needs the token as a secret.
        let secret = try await call(
            "PUT", "/repos/\(owner)/\(repo)/actions/secrets/E2E_TOKEN", body: try Http.encode(["data": adminToken]))
        guard secret.ok else { throw E2EError.failed("secret create failed: \(secret.status) \(secret.text)") }
    }

    public func stop() async {
        _ = try? await Shell.run("docker", ["rm", "-f", "-v", containerName], timeout: 60)
    }

    /// Freezes the server: connections are accepted by Docker's proxy but never answered, the way a hung or
    /// partitioned forge looks to kinhin and to the runners. `resume()` thaws it.
    public func pause() async throws {
        let paused = try await Shell.run("docker", ["pause", containerName], timeout: 60)
        guard paused.ok else { throw E2EError.failed("docker pause failed: \(paused.output)") }
    }

    public func resume() async throws {
        let resumed = try await Shell.run("docker", ["unpause", containerName], timeout: 60)
        guard resumed.ok else { throw E2EError.failed("docker unpause failed: \(resumed.output)") }
    }

    /// Gitea jobs here ask for the pool's one selecting label, as the docs show (`runs-on: kinhin-docker`).
    public nonisolated func jobLabels(for runtime: RuntimeKind) -> [String] { [runtime.runsOn] }

    public func pushWorkflow(name: String, labels: [String], nonce: String, script: String) async throws {
        let indented = script.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "          \($0)" }.joined(separator: "\n")
        let yaml = """
            name: \(name)
            on: [push]
            jobs:
              prove:
                runs-on: \(labels.count == 1 ? labels[0] : "[" + labels.joined(separator: ", ") + "]")
                steps:
                  - name: run
                    env:
                      E2E_TOKEN: ${{ secrets.E2E_TOKEN }}
                      E2E_NONCE: \(nonce)
                      E2E_API: \(base)/api/v1/repos/\(owner)/\(repo)
                    run: |
            \(indented)
            """
        let created = try await call(
            "POST", "/repos/\(owner)/\(repo)/contents/.gitea/workflows/\(name).yml",
            body: try Http.encode(["content": Data(yaml.utf8).base64EncodedString(), "message": "workflow \(name)"]))
        guard created.ok else {
            throw E2EError.failed("pushing the workflow failed: \(created.status) \(created.text)")
        }
    }

    public func proof(nonce: String) async throws -> String? {
        let response = try await call("GET", "/repos/\(owner)/\(repo)/issues?state=all&type=issues&limit=50")
        guard let issues = response.json as? [[String: Any]] else { return nil }
        for issue in issues where (issue["title"] as? String) == "proof-\(nonce)" {
            return issue["body"] as? String ?? ""
        }
        return nil
    }

    public func runStatuses() async throws -> [String] {
        let response = try await call("GET", "/repos/\(owner)/\(repo)/actions/tasks")
        guard let object = response.json as? [String: Any], let runs = object["workflow_runs"] as? [[String: Any]]
        else { return [] }
        return runs.compactMap { $0["status"] as? String }
    }

    public func registeredRunners() async throws -> [String] {
        let response = try await call("GET", "/repos/\(owner)/\(repo)/actions/runners")
        if let object = response.json as? [String: Any], let runners = object["runners"] as? [[String: Any]] {
            return runners.compactMap { $0["name"] as? String }
        }
        if let runners = response.json as? [[String: Any]] { return runners.compactMap { $0["name"] as? String } }
        return []
    }

    public func debugState() async -> String {
        var lines: [String] = []
        for path in ["/actions/runs", "/actions/jobs", "/actions/tasks", "/actions/runners"] {
            guard let response = try? await call("GET", "/repos/\(owner)/\(repo)\(path)") else { continue }
            var summary = response.text
            if let object = response.json as? [String: Any] {
                let list =
                    (object["workflow_runs"] ?? object["jobs"] ?? object["runners"]) as? [[String: Any]] ?? []
                summary = list.map { entry in
                    let keys = [
                        "id", "name", "status", "conclusion", "display_title", "runner_name", "labels", "run_id",
                    ]
                    return keys.compactMap { key in entry[key].map { "\(key)=\($0)" } }.joined(separator: " ")
                }.joined(separator: " | ")
            }
            lines.append("\(path): \(summary.prefix(900))")
        }
        return lines.joined(separator: "\n")
    }

    public func diagnostics() async -> String {
        let logs = try? await Shell.run("docker", ["logs", "--tail", "40", containerName], timeout: 30)
        return "[\(kind) logs]\n\(logs?.output ?? "unavailable")"
    }

    private func call(_ method: String, _ path: String, body: Data? = nil) async throws -> Http.Response {
        try await Http.request(method, api + path, headers: ["Authorization": "token \(adminToken)"], body: body)
    }

    public nonisolated func proofScript(extra: String) -> String {
        """
        set -e
        \(extra)
        BODY="$(uname -s) $(hostname) $(pwd) ${E2E_EXTRA:-}"
        curl -sf -X POST "$E2E_API/issues" -H "Authorization: token $E2E_TOKEN" \\
          -H "Content-Type: application/json" \\
          -d "{\\"title\\":\\"proof-$E2E_NONCE\\",\\"body\\":\\"$BODY\\"}"
        """
    }
}
