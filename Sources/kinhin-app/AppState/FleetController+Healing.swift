import KinhinKit

// MARK: - Healing decisions

// The throwing core of the healing approvals: callers that show their own
// failures (the Diagnostics sheet through `userApproveHealing`) wrap these.
@MainActor
extension FleetController {
    /// Carries out a fix that waits for approval. The engine starts it in the
    /// background, so the refresh shows it running and a later poll its outcome.
    func approveHealing(id: String) async throws {
        guard let service else { throw EngineError.fleetNotSetUp }
        do {
            try await service.approveHealing(id: id)
        } catch {
            await refresh()
            throw error
        }
        await refresh()
    }

    /// Closes a pending fix or a surfaced problem without acting on it.
    func dismissHealing(id: String) async throws {
        guard let service else { throw EngineError.fleetNotSetUp }
        do {
            try await service.dismissHealing(id: id)
        } catch {
            await refresh()
            throw error
        }
        await refresh()
    }
}
