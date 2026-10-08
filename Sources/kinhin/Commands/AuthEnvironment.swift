import Foundation
import KinhinKit

/// Injectable dependencies for the auth command. `.live` talks to the real
/// Keychain, stdin, forge APIs, and daemon socket; tests substitute recording
/// doubles so token flows never touch the login Keychain or the network.
///
/// The `fail`/`exit` hooks are throwing `Never`-returning functions: live
/// behavior terminates the process, tests throw a catchable error and assert
/// on the code/message instead.
struct AuthEnvironment: Sendable {
    var save: @Sendable (String, ForgeID) throws -> Void
    /// Returns the stored token for the forge, or nil when none is stored.
    var load: @Sendable (ForgeID) throws -> String?
    var delete: @Sendable (ForgeID) -> Void
    /// Interactive read for `auth set` without --token (raw stdin line).
    var readToken: @Sendable () -> String?
    /// `auth status` probe — throws when the forge rejects the token.
    var checkGitHub: @Sendable (GitHubCredentials) async throws -> Void
    var checkGitea: @Sendable (GiteaCredentials) async throws -> Void
    var checkGitLab: @Sendable (GitLabCredentials) async throws -> Void = { credentials in
        let report = await TokenHealthCheck.gitlab(
            token: credentials.token, scope: credentials.scope, instance: credentials.instance)
        guard report.ok else { throw CLIError(report.message) }
    }
    var checkBuildkite: @Sendable (BuildkiteCredentials) async throws -> Void = { credentials in
        let report = await TokenHealthCheck.buildkite(token: credentials.token, scope: credentials.scope)
        guard report.ok else { throw CLIError(report.message) }
    }
    var checkAzureDevOps: @Sendable (AzureDevOpsCredentials) async throws -> Void = { credentials in
        let report = await TokenHealthCheck.azureDevOps(
            token: credentials.token, scope: credentials.scope, instance: credentials.instance)
        guard report.ok else { throw CLIError(report.message) }
    }
    var checkBitbucket: @Sendable (BitbucketCredentials) async throws -> Void = { credentials in
        let report = await TokenHealthCheck.bitbucket(token: credentials.token, scope: credentials.scope)
        guard report.ok else { throw CLIError(report.message) }
    }
    var loadConfig: @Sendable () -> KinhinConfig
    /// Best-effort live-swap notification to a running daemon.
    var notifyDaemon: @Sendable (String, ForgeID) -> Void
    /// stderr `kinhin: <message>` + exit 1.
    var fail: @Sendable (String) throws -> Never
    /// Bare exit (stdout already carries the user-facing line).
    var exit: @Sendable (Int) throws -> Never
    /// Named-account token access (`--account NAME`, `auth add/remove`).
    var saveAccount: @Sendable (String, ForgeID, String) throws -> Void = {
        try KeychainTokenStore.save($0, forge: $1, name: $2)
    }
    var loadAccount: @Sendable (ForgeID, String) throws -> String? = {
        try KeychainTokenStore.load(forge: $0, name: $1)
    }
    var deleteAccount: @Sendable (ForgeID, String) -> Void = { KeychainTokenStore.delete(forge: $0, name: $1) }
    /// Best-effort live-swap notification for a named account: (account, token).
    var notifyDaemonAccount: @Sendable (String, String) -> Void = { account, token in
        notifyDaemonTokenReplaced(.account(account), token: token)
    }
    /// The config file `auth add/remove` edit.
    var configURL: URL = Paths.config
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

    /// The config account lookups read: the test fixture when set, else the
    /// live file (nil when missing or unreadable).
    var lookupConfig: KinhinConfig? {
        if let fixture = jsonConfig { fixture } else { Self.loadConfigTolerant() }
    }

    static let live = AuthEnvironment(
        save: { try KeychainTokenStore.save($0, forge: $1) },
        load: { try KeychainTokenStore.load(forge: $0) },
        delete: { KeychainTokenStore.delete(forge: $0) },
        readToken: { readSecretLine() },
        checkGitHub: { credentials in _ = try await GitHubClient(credentials: credentials).listRunners() },
        checkGitea: { credentials in _ = try await GiteaClient(credentials: credentials).fetchRegistrationToken() },
        loadConfig: { loadConfigOrExit() },
        notifyDaemon: { token, forge in notifyDaemonTokenReplaced(.forge(forge), token: token) },
        fail: { Self.fail($0) },
        exit: { Self.exit($0) }
    )
}
