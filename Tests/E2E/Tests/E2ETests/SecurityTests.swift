import E2ESupport
import Foundation
import Testing

/// Security promises from docs/security.md, checked against the real binary and a real daemon.
@Suite("Security", .serialized, .tags(.security), .enabled(if: E2E.enabled))
struct SecurityTests {
    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int, "no mode for \(url.path)")
    }

    @Test("the support directory, config, log directory and daemon socket are owner-only")
    func filesystemModes() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.dispose() }
        // The forge is unreachable on purpose: the daemon still serves RPC, and no real forge is needed here.
        try sandbox.writeConfig(
            """
            version: 1
            accounts:
              - name: gitea
                forge: gitea
                scope: acme/widgets
                instance: http://127.0.0.1:9
            """)
        sandbox.setToken("unreachable-forge-token", account: "gitea")
        let daemon = try await sandbox.startDaemon()
        defer { Task { await daemon.stop() } }

        #expect(try mode(sandbox.supportDirectory) == 0o700, "support dir")
        #expect(try mode(sandbox.configURL) == 0o600, "config")
        #expect(try mode(sandbox.supportDirectory.appendingPathComponent("logs")) == 0o700, "logs dir")
        #expect(try mode(sandbox.socketURL) == 0o600, "daemon socket")
        #expect(try mode(sandbox.logURL) == 0o600, "log file")
    }

    @Test("a forge on plain http is refused unless it is loopback or explicitly opted in")
    func plainHTTPPolicy() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.dispose() }
        func config(instance: String, optIn: Bool) -> String {
            """
            version: 1
            accounts:
              - name: gitea
                forge: gitea
                scope: acme/widgets
                instance: "\(instance)"
            \(optIn ? "    allow_insecure_http: true" : "")
            """
        }
        try sandbox.writeConfig(config(instance: "http://gitea.internal.example:3000", optIn: false))
        let refused = try await sandbox.kinhin(["config", "validate"])
        #expect(refused.status == 3, "plain http to a remote host must be refused: \(refused.output)")

        try sandbox.writeConfig(config(instance: "http://gitea.internal.example:3000", optIn: true))
        let optedIn = try await sandbox.kinhin(["config", "validate"])
        #expect(optedIn.ok, "an explicit opt-in is allowed: \(optedIn.output)")

        try sandbox.writeConfig(config(instance: "http://localhost:3000", optIn: false))
        let loopback = try await sandbox.kinhin(["config", "validate"])
        #expect(loopback.ok, "loopback http needs no opt-in: \(loopback.output)")
    }

    @Test("routing work onto the unisolated host needs explicit consent")
    func hostRuntimeNeedsConsent() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.dispose() }
        try sandbox.writeConfig("version: 1\n")
        let refused = try await sandbox.kinhin(["runtimes", "route", "add", "acme/api", "host"])
        #expect(!refused.ok, "a host route without --consent must be refused: \(refused.output)")
        #expect(!(try String(contentsOf: sandbox.configURL, encoding: .utf8).contains("acme/api")))

        let consented = try await sandbox.kinhin(["runtimes", "route", "add", "acme/api", "host", "--consent"])
        #expect(consented.ok, "with --consent it is allowed: \(consented.output)")
    }

    @Test("a token passed on stdin is never echoed, and never lands in the log")
    func tokensStayOutOfOutputAndLogs() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.dispose() }
        let secret = "ghp_\(E2E.randomID())\(E2E.randomID())\(E2E.randomID())"
        try sandbox.writeConfig(
            "version: 1\naccounts:\n  - name: github\n    forge: github\n    scope: acme/widgets\n")
        sandbox.setToken(secret, account: "github")
        for arguments in [["auth", "status"], ["auth", "list"], ["doctor"], ["config", "validate"]] {
            let result = try await sandbox.kinhin(arguments, timeout: 60)
            #expect(!result.output.contains(secret), "\(arguments.joined(separator: " ")) printed the token")
        }
        #expect(!sandbox.log().contains(secret), "the token reached the log")
    }
}
