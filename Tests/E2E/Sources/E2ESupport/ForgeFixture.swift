import Foundation

/// The forges the suite can stand up locally.
public enum ForgeKind: String, CaseIterable, Sendable, CustomStringConvertible {
    case gitea
    case forgejo
    case gitlab
    /// Gated: a real GitHub repository, used only when credentials are provided.
    case github

    public var description: String { rawValue }
}

/// What a lifecycle scenario needs from a real forge, whatever its API.
///
/// A fixture owns one throwaway server (a container), one repository and one access token. Scenarios push workflows
/// to it and judge the outcome by what the forge itself reports, never by kinhin's own view.
public protocol ForgeFixture: Sendable {
    var kind: ForgeKind { get }
    /// The `accounts:` entry that points kinhin at this forge. Valid after `start()`.
    var account: FleetConfig.Account { get async }
    /// The access token kinhin authenticates with. Valid after `start()`.
    var token: String { get async }
    /// True when the forge only reports queued work once a runner exists, so kinhin needs `min_runners: 1`.
    var needsRunnerFloor: Bool { get }

    func start() async throws
    func stop() async

    /// Pushes a workflow whose job runs `script` on a runner matching `runsOn`. The job's environment carries
    /// `E2E_NONCE`, `E2E_API` (the forge's API root for the repository) and `E2E_TOKEN`.
    func pushWorkflow(name: String, runsOn: String, nonce: String, script: String) async throws

    /// A job script that first runs `extra`, then opens the proof issue "proof-$E2E_NONCE" whose body is the guest's
    /// kernel name and hostname (plus `$E2E_EXTRA`). The issue is the evidence the job ran inside the guest.
    nonisolated func proofScript(extra: String) -> String

    /// The proof artifact for `nonce` once the job created it: the text the script wrote.
    func proof(nonce: String) async throws -> String?
    /// How the forge reports the most recent runs: `success`, `failure`, `running`, `waiting`.
    func runStatuses() async throws -> [String]
    /// Names of the runners the forge still has registered.
    func registeredRunners() async throws -> [String]
    /// Container logs, for a failure message.
    func diagnostics() async -> String
}

extension ForgeFixture {
    /// Waits for the proof artifact, failing with the forge's own diagnostics if it never appears.
    public func awaitProof(nonce: String, timeout: TimeInterval) async throws -> String {
        do {
            return try await eventually("proof \(nonce) from the job", timeout: timeout, interval: 3) {
                try await self.proof(nonce: nonce)
            }
        } catch {
            throw E2EError.failed(
                "\(error)\nforge statuses: \((try? await runStatuses()) ?? [])\n\(await diagnostics())")
        }
    }
}
