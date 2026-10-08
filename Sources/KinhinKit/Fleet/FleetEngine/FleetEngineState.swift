import Foundation

// MARK: - Routing state

/// The live routing model and its per-runtime caps, swapped together on reload.
struct RoutingState: Sendable {
    var model: RuntimeConfigModel
    var caps: [RuntimeID: Int]
}

/// Attached forges by account name, plus the bookkeeping that changes with
/// them.
struct ScaleSetAdminToken: Sendable {
    let token: String
    let actionsURL: URL
    let expiresAt: Date
    let sourceToken: String
}

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

/// The engine's serving flags, read by the reconcile loop and forge retry.
struct RunState: Sendable {
    var running = false
    var paused = false
    /// The reconcile loop should run its next pass now (`pollSoon()`).
    var pollNow = false
}
