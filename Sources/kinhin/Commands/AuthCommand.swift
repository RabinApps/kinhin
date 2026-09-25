import Foundation
import KinhinKit

/// Injectable dependencies for the auth command. `.live` talks to the real
/// Keychain, stdin, forge APIs, and daemon socket; tests substitute recording
/// doubles so token flows never touch the login Keychain or the network.
///
/// The `fail`/`exit` hooks are throwing `Never`-returning functions: live
/// behavior terminates the process, tests throw a catchable error and assert
/// on the code/message instead.
struct AuthEnvironment {
    var save: (String, ForgeID) throws -> Void
    /// Returns the stored token for the forge, or nil when none is stored.
    var load: (ForgeID) -> String?
    var delete: (ForgeID) -> Void
    /// Interactive read for `auth set` without --token (raw stdin line).
    var readToken: () -> String?
    /// `auth status` probe — throws when the forge rejects the token.
    var checkGitHub: (GitHubCredentials) async throws -> Void
    var checkGitea: (GiteaCredentials) async throws -> Void
    var loadConfig: () -> KinhinConfig
    /// Best-effort live-swap notification to a running daemon.
    var notifyDaemon: (String, ForgeID) -> Void
    /// stderr `kinhin: <message>` + exit 1.
    var fail: (String) throws -> Never
    /// Bare exit (stdout already carries the user-facing line).
    var exit: (Int) throws -> Never
    /// Config fixture for `auth status --json`: nil property → read the live
    /// file (tolerant of a missing one); a set value → use it instead, so
    /// tests never touch the developer's real config.
    var jsonConfig: KinhinConfig?? = nil

    /// Static so `live`'s initializer can reference them without touching
    /// instance state (Swift forbids instance members in property initializers).
    static func fail(_ message: String) -> Never {
        kinhin.fail(message, exit: .auth)
    }

    static func exit(_ code: Int) -> Never {
        Foundation.exit(Int32(code))
    }

    /// `auth status --json` works without a config file — the report's
    /// job is to *report* what's missing, not die on it.
    static func loadConfigTolerant() -> KinhinConfig? {
        try? ConfigLoader.load()
    }

    static let live = AuthEnvironment(
        save: { try KeychainTokenStore.save($0, forge: $1) },
        load: { KeychainTokenStore.load(forge: $0) },
        delete: { KeychainTokenStore.delete(forge: $0) },
        readToken: { String(data: FileHandle.standardInput.availableData, encoding: .utf8) },
        checkGitHub: { credentials in _ = try await GitHubClient(credentials: credentials).listRunners() },
        checkGitea: { credentials in _ = try await GiteaClient(credentials: credentials).fetchRegistrationToken() },
        loadConfig: { loadConfigOrExit() },
        notifyDaemon: { token, forge in
            if forge == .gitea {
                notifyDaemonGiteaTokenReplaced(token)
            } else {
                notifyDaemonTokenReplaced(token)
            }
        },
        fail: { Self.fail($0) },
        exit: { Self.exit($0) }
    )
}

enum AuthCommand {
    /// Builds, prints, and returns the machine-readable status document.
    /// Static — no network probes, tolerant of a missing config file.
    static func emitStatusJSON(environment: AuthEnvironment) throws -> (report: AuthStatusReport, data: Data) {
        let report = AuthStatusReporter.report(
            config: environment.jsonConfig ?? AuthEnvironment.loadConfigTolerant(),
            load: environment.load
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        print(String(decoding: data, as: UTF8.self))
        return (report, data)
    }

    /// `environment` is injectable so tests can drive every flow with
    /// recording doubles — no real Keychain, stdin, or network.
    static func run(_ args: [String], environment: AuthEnvironment = .live) async throws {
        let sub = args.dropFirst().first ?? "set"
        // Platform selection: --gitea targets the Gitea token; default is GitHub.
        let giteaMode = args.contains("--gitea")
        let forge: ForgeID = giteaMode ? .gitea : .github
        let forgeName = giteaMode ? "Gitea access token" : "GitHub PAT"
        switch sub {
        case "set":
            let token: String
            if let explicit = flag("--token", in: args) {
                token = explicit
            } else {
                print("Paste your \(forgeName) (input hidden), then press Enter:")
                let entered = environment.readToken()?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let entered, !entered.isEmpty else {
                    try environment.fail("no token entered")
                }
                token = entered
            }
            try environment.save(token, forge)
            environment.notifyDaemon(token, forge)
            print("\(forgeName) stored in Keychain")
        case "status":
            // Machine output first: the whole point is a fast, deterministic,
            // scriptable snapshot — never a network probe, never an early
            // exit before the JSON lands.
            if args.contains("--json") {
                let (report, _) = try Self.emitStatusJSON(environment: environment)
                if !report.allGood {
                    try environment.exit(1)
                }
                return
            }
            guard let token = environment.load(forge) else {
                print(giteaMode ? "no Gitea token stored" : "no token stored")
                try environment.exit(1)
            }
            let cfg = environment.loadConfig()
            if giteaMode {
                guard let gitea = cfg.gitea else {
                    try environment.fail("no gitea section in config — add it before checking the Gitea token")
                }
                print("Gitea token stored (starts with \(token.prefix(4))…), checking \(gitea.instance)…")
                do {
                    try await environment.checkGitea(
                        GiteaCredentials(token: token, scope: gitea.scope, instance: gitea.instance))
                    print("token works against \(gitea.scope) @ \(gitea.instance)")
                } catch {
                    print("token check failed: \(error.localizedDescription)")
                    try environment.exit(1)
                }
            } else {
                print("token stored (starts with \(token.prefix(4))…), checking…")
                do {
                    try await environment.checkGitHub(GitHubCredentials(token: token, scope: cfg.repo))
                    print("token works against \(cfg.repo)")
                } catch {
                    print("token check failed: \(error.localizedDescription)")
                    try environment.exit(1)
                }
            }
        case "clear":
            environment.delete(forge)
            print("\(forgeName) removed")
        default:
            try environment.fail("unknown auth subcommand '\(sub)' (use set|status|clear)")
        }
    }
}
