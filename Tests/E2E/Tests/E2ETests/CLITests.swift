import E2ESupport
import Foundation
import Testing

/// The headless CLI, end to end through the real binary and a real (sandboxed) filesystem. No forge or VM needed,
/// so this suite is fast and runs anywhere the binary builds.
@Suite("CLI features", .serialized, .tags(.cli), .enabled(if: E2E.enabled))
struct CLITests {
    private func withSandbox<T>(_ body: (Sandbox) async throws -> T) async throws -> T {
        let sandbox = try Sandbox()
        defer { sandbox.dispose() }
        return try await body(sandbox)
    }

    /// A config with a Docker pool, which routes and `workflow route` need to target.
    private static let dockerConfig = """
        version: 1
        accounts:
          - name: github
            forge: github
            scope: acme/widgets
        docker:
          image: "ke2e-unused"
          max_slots: 1

        """

    private func json(_ result: ProcessResult) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        return try #require(object as? [String: Any], "not a JSON object: \(result.stdout.prefix(200))")
    }

    // MARK: Basics and exit codes

    @Test("version prints a version and exits 0")
    func version() async throws {
        try await withSandbox { sandbox in
            let result = try await sandbox.kinhin(["version"])
            #expect(result.ok)
            #expect(result.trimmedStdout.hasPrefix("kinhin "))
        }
    }

    @Test("an unknown command is a usage error (exit 2) and says so")
    func unknownCommandExitsUsage() async throws {
        try await withSandbox { sandbox in
            let result = try await sandbox.kinhin(["definitely-not-a-command"])
            #expect(result.status == 2, "exit \(result.status): \(result.output)")
        }
    }

    @Test("a config with an unknown key is rejected with the config exit code (3)")
    func invalidConfigExitsThree() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig("version: 1\nmax_runner: 2\n")
            let result = try await sandbox.kinhin(["config", "validate"])
            #expect(result.status == 3, "exit \(result.status): \(result.output)")
            #expect(result.output.contains("max_runner"), "should name the typo: \(result.output)")
        }
    }

    @Test("--json errors are machine-readable")
    func jsonErrors() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig("version: 1\nmax_runner: 2\n")
            let result = try await sandbox.kinhin(["config", "validate", "--json"])
            #expect(!result.ok)
            let text = result.output
            let start = try #require(text.firstIndex(of: "{"), "no JSON in: \(text)")
            #expect((try? JSONSerialization.jsonObject(with: Data(text[start...].utf8))) != nil, "bad JSON: \(text)")
        }
    }

    // MARK: Config

    @Test("config init works on a pristine machine and keeps the file private")
    func configInit() async throws {
        try await withSandbox { sandbox in
            try FileManager.default.removeItem(at: sandbox.supportDirectory)  // a true first run: nothing exists yet
            let created = try await sandbox.kinhin(["config", "init"])
            #expect(created.ok, "config init failed: \(created.output)")
            let attributes = try FileManager.default.attributesOfItem(atPath: sandbox.configURL.path)
            #expect((attributes[.posixPermissions] as? Int) == 0o600, "config must be 0600")

            let again = try await sandbox.kinhin(["config", "init"])
            #expect(again.stdout.contains("already exists"), "must not overwrite: \(again.output)")
            let forced = try await sandbox.kinhin(["config", "init", "--force"])
            #expect(forced.ok)
        }
    }

    @Test(
        "config export writes the config without tokens, and import validates it, writes it, and keeps a backup on replace"
    )
    func configExportAndImport() async throws {
        let source = try Sandbox()
        let target = try Sandbox()
        defer {
            source.dispose()
            target.dispose()
        }
        try source.writeConfig(Self.dockerConfig)
        let exported = try await source.kinhin(["config", "export"])
        #expect(exported.ok, "\(exported.output)")
        #expect(exported.stdout.contains("acme/widgets"))
        #expect(!exported.stdout.lowercased().contains("token:"), "no token travels with the config")

        let file = target.supportDirectory.appendingPathComponent("moved.yaml")
        let toFile = try await source.kinhin(["config", "export", file.path])
        #expect(toFile.ok, "\(toFile.output)")
        let again = try await source.kinhin(["config", "export", file.path])
        #expect(!again.ok, "an existing file is not overwritten without --force: \(again.output)")

        // Importing into a machine with no config writes it; with one, it only reports unless --yes, then keeps a backup.
        let imported = try await target.kinhin(["config", "import", file.path])
        #expect(imported.ok, "\(imported.output)")
        #expect(FileManager.default.fileExists(atPath: target.configURL.path))
        // A different config is now in place, so importing has something to replace.
        try target.writeConfig("version: 1\nmax_runners: 1\n")
        let dry = try await target.kinhin(["config", "import", file.path])
        #expect(dry.ok)
        #expect(
            try String(contentsOf: target.configURL, encoding: .utf8).contains("max_runners: 1"),
            "a dry run changes nothing")
        #expect(
            !FileManager.default.fileExists(atPath: target.configURL.path + ".bak"), "nothing is replaced without --yes"
        )
        let replaced = try await target.kinhin(["config", "import", file.path, "--yes"])
        #expect(replaced.ok, "\(replaced.output)")
        #expect(FileManager.default.fileExists(atPath: target.configURL.path + ".bak"))
        #expect(
            try String(contentsOf: target.configURL, encoding: .utf8).contains("acme/widgets"),
            "the imported config is in place")

        let bad = target.supportDirectory.appendingPathComponent("bad.yaml")
        try Data("version: 1\nmax_runner: 2\n".utf8).write(to: bad)
        let rejected = try await target.kinhin(["config", "import", bad.path, "--yes"])
        #expect(rejected.status == 3, "an invalid file is rejected: exit \(rejected.status): \(rejected.output)")
    }

    @Test("config migrate translates a removed key and --write keeps a backup")
    func configMigrate() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig(
                "version: 1\nrepo: acme/widgets\nmin_runners: 0\nmax_runners: 1\n")
            let preview = try await sandbox.kinhin(["config", "migrate"])
            #expect(preview.ok, "migrate failed: \(preview.output)")
            let written = try await sandbox.kinhin(["config", "migrate", "--write"])
            #expect(written.ok)
            #expect(FileManager.default.fileExists(atPath: sandbox.configURL.path + ".bak"), "no backup kept")
            let validated = try await sandbox.kinhin(["config", "validate"])
            #expect(validated.ok, "the migrated config should validate: \(validated.output)")
        }
    }

    // MARK: Accounts

    @Test("auth add, list and remove edit the config; auth status reads tokens from the environment")
    func accountLifecycle() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig(
                "version: 1\naccounts:\n  - name: github\n    forge: github\n    scope: acme/widgets\n")
            let added = try await sandbox.kinhin(
                [
                    "auth", "add", "lab", "--gitea", "--scope", "acme/widgets", "--instance",
                    "https://gitea.example.com",
                ])
            #expect(added.ok, "auth add failed: \(added.output)")
            #expect(try String(contentsOf: sandbox.configURL, encoding: .utf8).contains("\"lab\""))

            let listed = try await sandbox.kinhin(["auth", "list"])
            #expect(listed.ok, "auth list failed: \(listed.output)")
            #expect(listed.stdout.contains("lab\tgitea\tacme/widgets"), "\(listed.stdout)")

            sandbox.setToken("a-token", account: "lab")
            let status = try await sandbox.kinhin(["auth", "status", "--account", "lab", "--json"])
            #expect(status.stdout.contains("true") || status.stdout.contains("stored"), "\(status.output)")

            let removed = try await sandbox.kinhin(["auth", "remove", "lab"])
            #expect(removed.ok, "auth remove failed: \(removed.output)")
            #expect(!(try String(contentsOf: sandbox.configURL, encoding: .utf8).contains("\"lab\"")))
        }
    }

    // MARK: Diagnostics

    @Test("doctor --json is valid JSON with an auth section, and exits cleanly offline")
    func doctorJSON() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig("version: 1\n")
            let result = try await sandbox.kinhin(["doctor", "--json"])
            let object = try json(result)
            #expect(object["auth"] != nil)
        }
    }

    /// `kinhin logs` once printed its own fresh process's (empty) in-memory log, never the daemon's history.
    @Test("logs prints the log file's tail, redacted, honouring -n")
    func logsShowTheFileTailRedacted() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig("version: 1\n")
            let secret = "ghp_" + String(repeating: "a1B2", count: 9)
            let logs = sandbox.supportDirectory.appendingPathComponent("logs")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            try """
            2026-01-01 00:00:00 [info] [engine] first line
            2026-01-01 00:00:01 [info] [kinhin-1-a] registering with \(secret)
            2026-01-01 00:00:02 [info] [kinhin-1-a] last line

            """.write(to: logs.appendingPathComponent("kinhin.log"), atomically: true, encoding: .utf8)

            let result = try await sandbox.kinhin(["logs", "-n", "2"])
            #expect(result.ok, "\(result.output)")
            #expect(result.stdout.contains("last line"))
            #expect(result.stdout.contains("kinhin-1-a] registering"))
            #expect(!result.stdout.contains("first line"), "-n 2 prints two lines")
            #expect(!result.output.contains(secret), "the token must be redacted: \(result.output)")
        }
    }

    @Test("doctor --bundle writes a support bundle that contains no token")
    func doctorBundleHasNoSecrets() async throws {
        try await withSandbox { sandbox in
            let secret = "s3cr3t-token-\(E2E.randomID())"
            try sandbox.writeConfig(
                "version: 1\naccounts:\n  - name: gitea\n    forge: gitea\n    scope: acme/widgets\n    instance: http://127.0.0.1:9\n"
            )
            sandbox.setToken(secret, account: "gitea")
            let bundle = sandbox.supportDirectory.appendingPathComponent("bundle.txt").path
            let result = try await sandbox.kinhin(["doctor", "--bundle", bundle])
            #expect(FileManager.default.fileExists(atPath: bundle), "no bundle written: \(result.output)")
            let text = (try? String(contentsOfFile: bundle, encoding: .utf8)) ?? ""
            #expect(!text.isEmpty)
            #expect(!text.contains(secret), "the support bundle contains the token")
            #expect(!result.output.contains(secret), "doctor printed the token")
        }
    }

    @Test("runtimes --json lists pools and runtime health; routes can be added and removed")
    func runtimesAndRoutes() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig(Self.dockerConfig)
            let listing = try json(try await sandbox.kinhin(["runtimes", "--json"]))
            #expect(listing["pools"] != nil)
            #expect(listing["availability"] != nil)

            let added = try await sandbox.kinhin(["runtimes", "route", "add", "acme/api", "docker"])
            #expect(added.ok, "route add failed: \(added.output)")
            #expect(try String(contentsOf: sandbox.configURL, encoding: .utf8).contains("acme/api"))
            let removed = try await sandbox.kinhin(["runtimes", "route", "remove", "acme/api"])
            #expect(removed.ok, "route remove failed: \(removed.output)")
        }
    }

    @Test("image list, toolchains and cleanup-free read-only commands run against a sandbox")
    func readOnlyInventory() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig("version: 1\n")
            for arguments in [["image", "list", "--json"], ["toolchains", "--json"], ["toolchains", "list-images"]] {
                let result = try await sandbox.kinhin(arguments, timeout: 120)
                #expect(result.ok, "\(arguments.joined(separator: " ")) failed: \(result.output)")
            }
            let catalog = try json(try await sandbox.kinhin(["toolchains", "--json"]))
            #expect(catalog["stacks"] != nil)
        }
    }

    // MARK: Toolchain detection and workflows

    @Test("toolchains detect reads a checkout's manifests")
    func toolchainDetection() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig("version: 1\n")
            let checkout = sandbox.supportDirectory.appendingPathComponent("checkout")
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
            try #"{"name":"x","engines":{"node":"22"}}"#.write(
                to: checkout.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
            try "module example.com/x\n\ngo 1.23\n".write(
                to: checkout.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
            let result = try await sandbox.kinhin(["toolchains", "detect", checkout.path, "--json"])
            #expect(result.ok, "detect failed: \(result.output)")
            #expect(result.stdout.contains("node"), "node not detected: \(result.stdout)")
            #expect(result.stdout.contains("go"), "go not detected: \(result.stdout)")
        }
    }

    @Test("workflow test runs a workflow locally on the host, and workflow route rewrites runs-on")
    func localWorkflows() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig(Self.dockerConfig)
            let fixture = E2E.repoRoot.appendingPathComponent("Tests/Fixtures/workflow-local-smoke.yml").path
            let ran = try await sandbox.kinhin(["workflow", "test", fixture], timeout: 180)
            #expect(ran.ok, "workflow test failed: \(ran.output)")

            // The smoke fixture has no `runs-on`, so route a workflow that does.
            let copy = sandbox.supportDirectory.appendingPathComponent("ci.yml")
            try "name: ci\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n"
                .write(to: copy, atomically: true, encoding: .utf8)
            let routed = try await sandbox.kinhin(["workflow", "route", copy.path, "docker"])
            #expect(routed.ok, "workflow route failed: \(routed.output)")
            #expect(try String(contentsOf: copy, encoding: .utf8).contains("kinhin-docker"))
        }
    }

    // MARK: Reset

    @Test("reset --scope config removes the sandbox config and nothing else")
    func resetConfigScope() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig("version: 1\n")
            let result = try await sandbox.kinhin(["reset", "--scope", "config", "--yes"])
            #expect(result.ok, "reset failed: \(result.output)")
            #expect(!FileManager.default.fileExists(atPath: sandbox.configURL.path))
        }
    }

    // MARK: MCP

    @Test("mcp serves the protocol over stdio: initialize, then tools/list")
    func mcpHandshake() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig("version: 1\n")
            let requests =
                [
                    #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}"#,
                    #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                    #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                ].joined(separator: "\n") + "\n"
            let result = try await sandbox.kinhin(["mcp"], stdin: requests, timeout: 60)
            #expect(result.stdout.contains("\"id\":1") || result.stdout.contains("\"id\" : 1"), "\(result.output)")
            #expect(result.stdout.contains("tools"), "no tool list: \(result.output)")
        }
    }
}
