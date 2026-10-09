import Foundation

/// A real GitHub repository, for the one forge that cannot be self-hosted. Gated: it runs only when
/// `KINHIN_E2E_GITHUB_TOKEN` (a PAT that may manage runners and workflows) and `KINHIN_E2E_GITHUB_REPO`
/// (`owner/name` of a **throwaway** repository) are set. It leaves nothing behind: `stop()` deletes the workflow
/// files it pushed and closes its proof issues.
///
/// Not verified live in the session that wrote it (no throwaway repository was available); the first run on a
/// machine with credentials is its acceptance test.
public actor GitHubFixture: ForgeFixture {
    public nonisolated let kind = ForgeKind.github
    public nonisolated let needsRunnerFloor = false

    public static var isConfigured: Bool {
        E2E.flag("KINHIN_E2E_GITHUB_TOKEN") != nil && E2E.flag("KINHIN_E2E_GITHUB_REPO") != nil
    }

    private let repo: String
    private let pat: String
    private var pushedPaths: [String] = []

    public init() throws {
        guard let token = E2E.flag("KINHIN_E2E_GITHUB_TOKEN"), let repo = E2E.flag("KINHIN_E2E_GITHUB_REPO") else {
            throw E2EError.unavailable("set KINHIN_E2E_GITHUB_TOKEN and KINHIN_E2E_GITHUB_REPO")
        }
        pat = token
        self.repo = repo
    }

    public var account: FleetConfig.Account {
        FleetConfig.Account(name: "github", forge: "github", scope: repo)
    }

    public var token: String { pat }

    public func start() async throws {
        let probe = try await call("GET", "")
        guard probe.ok else { throw E2EError.failed("cannot read \(repo) with the given token: \(probe.status)") }
    }

    public func stop() async {
        for path in pushedPaths {
            guard let existing = try? await call("GET", "/contents/\(path)"),
                let object = existing.json as? [String: Any], let sha = object["sha"] as? String,
                let body = try? Http.encode(["message": "e2e cleanup", "sha": sha])
            else { continue }
            _ = try? await call("DELETE", "/contents/\(path)", body: body)
        }
        pushedPaths.removeAll()
    }

    public nonisolated func proofScript(extra: String) -> String {
        """
        set -e
        \(extra)
        BODY="$(uname -s) $(hostname) ${E2E_EXTRA:-}"
        curl -sf -X POST "$E2E_API/issues" -H "Authorization: Bearer $E2E_TOKEN" \\
          -H "Accept: application/vnd.github+json" -H "Content-Type: application/json" \\
          -d "{\\"title\\":\\"proof-$E2E_NONCE\\",\\"body\\":\\"$BODY\\"}"
        """
    }

    public func pushWorkflow(name: String, runsOn: String, nonce: String, script: String) async throws {
        let path = ".github/workflows/e2e-\(name)-\(nonce).yml"
        let indented = script.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "          \($0)" }.joined(separator: "\n")
        // `paths` limits the trigger to this workflow's own commit, so earlier files do not run again.
        let yaml = """
            name: e2e-\(name)-\(nonce)
            on:
              push:
                paths: ['\(path)']
            permissions:
              issues: write
            jobs:
              prove:
                runs-on: [self-hosted, linux, arm64, \(runsOn)]
                steps:
                  - name: run
                    env:
                      E2E_TOKEN: ${{ secrets.GITHUB_TOKEN }}
                      E2E_NONCE: \(nonce)
                      E2E_API: https://api.github.com/repos/\(repo)
                    run: |
            \(indented)
            """
        let body = try Http.encode([
            "message": "e2e workflow \(name)", "content": Data(yaml.utf8).base64EncodedString(),
        ])
        let response = try await call("PUT", "/contents/\(path)", body: body)
        guard response.ok else {
            throw E2EError.failed("pushing the workflow failed: \(response.status) \(response.text)")
        }
        pushedPaths.append(path)
    }

    public func proof(nonce: String) async throws -> String? {
        let response = try await call("GET", "/issues?state=all&per_page=50")
        guard let issues = response.json as? [[String: Any]] else { return nil }
        for issue in issues where (issue["title"] as? String) == "proof-\(nonce)" {
            return issue["body"] as? String ?? ""
        }
        return nil
    }

    public func runStatuses() async throws -> [String] {
        let response = try await call("GET", "/actions/runs?per_page=10")
        guard let object = response.json as? [String: Any], let runs = object["workflow_runs"] as? [[String: Any]]
        else { return [] }
        return runs.compactMap { ($0["conclusion"] as? String) ?? ($0["status"] as? String) }
    }

    public func registeredRunners() async throws -> [String] {
        let response = try await call("GET", "/actions/runners")
        guard let object = response.json as? [String: Any], let runners = object["runners"] as? [[String: Any]]
        else { return [] }
        return runners.compactMap { $0["name"] as? String }
    }

    public func diagnostics() async -> String { "[github] repo \(repo)" }

    private func call(_ method: String, _ path: String, body: Data? = nil) async throws -> Http.Response {
        try await Http.request(
            method, "https://api.github.com/repos/\(repo)\(path)",
            headers: ["Authorization": "Bearer \(pat)", "Accept": "application/vnd.github+json"], body: body,
            timeout: 60)
    }
}
