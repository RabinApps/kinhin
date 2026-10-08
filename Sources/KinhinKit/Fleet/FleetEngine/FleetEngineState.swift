import Foundation

/// An Actions-service JWT exchanged for an account's registration token.
struct ScaleSetAdminToken: Sendable {
    let token: String
    let actionsURL: URL
    let expiresAt: Date
    let sourceToken: String
}

/// Attached forges by account name, plus the bookkeeping that changes with
/// them.
struct ForgeState: Sendable {
    var byPlatform: [String: Forge] = [:]
    /// Actions-service JWTs exchanged from account PAT registration tokens.
    var scaleSetAdminTokens: [String: ScaleSetAdminToken] = [:]
    /// Registration-token caches, one per account (created on first use).
    var accountRegistrationTokens: [String: RegistrationTokenCache] = [:]
    /// Scale-set message listeners attached to running accounts.
    var scaleSetListeners: [String: [GitHubScaleSetListener]] = [:]
    /// Retry schedule for forges that failed at startup (FleetForgeRetry.swift).
    var retry = ForgeRetryState()
}

/// Deletes in progress, behind the engine's `deletes` lock.
struct DeleteState: Sendable {
    /// Instances a `deleteVMRecord` is tearing down right now (from any caller).
    var inFlight: Set<String> = []
    /// The background task of each delete the reconcile pass started, by instance id.
    var tasks: [String: Task<Void, Never>] = [:]
}

/// The engine's serving flags, read by the reconcile loop and forge retry.
struct RunState: Sendable {
    var running = false
    var paused = false
    /// The reconcile loop should run its next pass now (`pollSoon()`).
    var pollNow = false
}
