import Foundation

// GitHubScaleSetListener — just-in-time runner config generation.
extension GitHubScaleSetListener {
    /// Forge-owned JIT config generation via the listener's underlying scale-set
    /// client. Kept on the listener so the Forge adapter does not need privileged
    /// access to the listener's private `client` property.
    public func generateJitConfig(
        scaleSetId: Int, name: String, workFolder: String
    ) async throws -> GitHubScaleSetJitConfig {
        do {
            return try await client.generateJitConfig(
                scaleSetId: scaleSetId, name: name, workFolder: workFolder)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ScaleSetError.jitConfigFailure(reason: error.localizedDescription)
        }
    }
}
