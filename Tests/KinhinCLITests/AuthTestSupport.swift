import Synchronization
import XCTest

@testable import KinhinKit
@testable import kinhin

/// Shared harness for the auth command tests: a recording `AuthEnvironment`
/// double (no real Keychain, stdin, network, or daemon socket) plus the
/// catchable fail/exit error types. `AuthCommandTests`,
/// `AuthAccountsCommandTests`, and `AuthStatusReportTests` build on it.
enum AuthTestSupport {
    /// Thrown by the environment's `fail` hook (stderr message + exit 1).
    struct AuthFailure: Error { let message: String }
    /// Thrown by the environment's `exit` hook (stdout already printed).
    struct AuthExit: Error { let code: Int }
    /// A caller-supplied error re-thrown by the save hook.
    struct SaveError: Error {}
    /// A caller-supplied error re-thrown by the check hooks.
    struct CheckError: Error {}
}

/// Recording double for every hook the auth environment exposes. All state
/// is Mutex-guarded so its closures are `@Sendable` (AuthEnvironment
/// requires Sendable closure fields).
final class AuthRecorder: Sendable {
    private struct Snapshot: Sendable {
        var events: [String] = []
        var saved: [(token: String, forge: ForgeID)] = []
        var deleted: [ForgeID] = []
        var notified: [(token: String, forge: ForgeID)] = []
        var savedAccounts: [(token: String, forge: ForgeID, name: String)] = []
        var deletedAccounts: [(ForgeID, String)] = []
        var notifiedAccounts: [(account: String, token: String)] = []
        var checkedGitHub: [GitHubCredentials] = []
        var checkedGitea: [GiteaCredentials] = []
        var checkedGitLab: [GitLabCredentials] = []
        var checkedBuildkite: [BuildkiteCredentials] = []
    }

    private let state = Mutex(Snapshot())

    var events: [String] { state.withLock { $0.events } }
    var saved: [(token: String, forge: ForgeID)] { state.withLock { $0.saved } }
    var deleted: [ForgeID] { state.withLock { $0.deleted } }
    var notified: [(token: String, forge: ForgeID)] { state.withLock { $0.notified } }
    var savedAccounts: [(token: String, forge: ForgeID, name: String)] { state.withLock { $0.savedAccounts } }
    var deletedAccounts: [(ForgeID, String)] { state.withLock { $0.deletedAccounts } }
    var notifiedAccounts: [(account: String, token: String)] { state.withLock { $0.notifiedAccounts } }
    var checkedGitHub: [GitHubCredentials] { state.withLock { $0.checkedGitHub } }
    var checkedGitea: [GiteaCredentials] { state.withLock { $0.checkedGitea } }
    var checkedGitLab: [GitLabCredentials] { state.withLock { $0.checkedGitLab } }
    var checkedBuildkite: [BuildkiteCredentials] { state.withLock { $0.checkedBuildkite } }

    private func append(_ keyPath: WritableKeyPath<Snapshot, [String]>, _ value: String) {
        state.withLock { $0[keyPath: keyPath] = $0[keyPath: keyPath] + [value] }
    }

    func recordSave(_ token: String, _ forge: ForgeID) {
        state.withLock {
            $0.saved.append((token, forge)); $0.events.append("save:\(forge.rawValue)")
        }
    }

    func recordDelete(_ forge: ForgeID) {
        state.withLock {
            $0.deleted.append(forge); $0.events.append("delete:\(forge.rawValue)")
        }
    }

    func recordNotify(_ token: String, _ forge: ForgeID) {
        state.withLock {
            $0.notified.append((token, forge)); $0.events.append("notify:\(forge.rawValue)")
        }
    }

    func recordSaveAccount(_ token: String, _ forge: ForgeID, _ name: String) {
        state.withLock { $0.savedAccounts.append((token, forge, name)) }
    }

    func recordDeleteAccount(_ forge: ForgeID, _ name: String) {
        state.withLock { $0.deletedAccounts.append((forge, name)) }
    }

    func recordNotifyAccount(_ account: String, _ token: String) {
        state.withLock { $0.notifiedAccounts.append((account, token)) }
    }

    func recordCheckGitHub(_ credentials: GitHubCredentials) {
        state.withLock { $0.checkedGitHub.append(credentials) }
    }

    func recordCheckGitea(_ credentials: GiteaCredentials) {
        state.withLock { $0.checkedGitea.append(credentials) }
    }

    func recordCheckGitLab(_ credentials: GitLabCredentials) {
        state.withLock { $0.checkedGitLab.append(credentials) }
    }

    func recordCheckBuildkite(_ credentials: BuildkiteCredentials) {
        state.withLock { $0.checkedBuildkite.append(credentials) }
    }
}

extension AuthCommandTests {
    /// Builds an environment over the shared recorder. `stored` maps a ForgeID
    /// to a token for the legacy per-forge items; the account hooks report
    /// nothing unless `accountTokens` does.
    func makeRecorderEnvironment(
        stored: [ForgeID: String] = [:],
        accountTokens: [String: String] = [:],
        config: KinhinConfig,
        readToken: (@Sendable () -> String?)? = nil,
        checkError: Error? = nil,
        saveError: Error? = nil,
        recorder: AuthRecorder
    ) -> AuthEnvironment {
        let frozen = config
        return AuthEnvironment(
            save: { token, forge in
                if let saveError { throw saveError }
                recorder.recordSave(token, forge)
            },
            load: { stored[$0] },
            delete: { forge in
                recorder.recordDelete(forge)
            },
            readToken: readToken ?? { nil },
            checkGitHub: { credentials in
                recorder.recordCheckGitHub(credentials)
                if let checkError { throw checkError }
            },
            checkGitea: { credentials in
                recorder.recordCheckGitea(credentials)
                if let checkError { throw checkError }
            },
            loadConfig: { frozen },
            notifyDaemon: { token, forge in
                recorder.recordNotify(token, forge)
            },
            fail: { throw AuthTestSupport.AuthFailure(message: $0) },
            exit: { throw AuthTestSupport.AuthExit(code: $0) }
        )
    }
}

extension AuthAccountsCommandTests {
    /// Builds the accounts-flavored environment: named-account hooks active,
    /// legacy per-forge save/delete/notify hooks tripwire-fail. Resolves
    /// everything it needs from `self` up front so the closures only capture
    /// Sendable state.
    func makeAccountsEnvironment(
        _ recorder: AuthRecorder, stored: [String: String] = [:], readToken: String? = nil
    ) -> AuthEnvironment {
        let frozen = frozenConfig
        let url = configURL
        var env = AuthEnvironment(
            save: { _, _ in XCTFail("legacy save must not be used for a named account") },
            load: { _ in nil },
            delete: { _ in XCTFail("legacy delete must not be used for a named account") },
            readToken: { readToken },
            checkGitHub: { recorder.recordCheckGitHub($0) },
            checkGitea: { recorder.recordCheckGitea($0) },
            loadConfig: { frozen },
            notifyDaemon: { _, _ in XCTFail("legacy notify must not be used for a named account") },
            fail: { throw AuthTestSupport.AuthFailure(message: $0) },
            exit: { throw AuthTestSupport.AuthExit(code: $0) }
        )
        env.checkGitLab = { recorder.recordCheckGitLab($0) }
        env.checkBuildkite = { recorder.recordCheckBuildkite($0) }
        env.saveAccount = { token, forge, name in recorder.recordSaveAccount(token, forge, name) }
        env.loadAccount = { _, name in stored[name] }
        env.deleteAccount = { recorder.recordDeleteAccount($0, $1) }
        env.notifyDaemonAccount = { recorder.recordNotifyAccount($0, $1) }
        env.configURL = url!
        env.jsonConfig = .some(frozen)
        return env
    }

    /// The on-disk config, frozen at first use so closures can capture it.
    var frozenConfig: KinhinConfig {
        if let frozen { return frozen }
        let parsed = (try? ConfigLoader.load(from: configURL)) ?? KinhinConfig.default
        frozen = parsed
        return parsed
    }
}
