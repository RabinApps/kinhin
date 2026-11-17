import Foundation

// MARK: - The Docker Hub cache probe

extension DoctorReportBuilder {
    /// The Docker Hub cache's state for the container section, read live without starting it. When the container
    /// runtime is not ready its CLI cannot be asked, so the cache reads as not running, with the reason.
    static func registryCacheStatus(
        runtimeReady: Bool, cache: DockerRegistryCache = DockerRegistryCache()
    ) async -> DoctorReport.RegistryCacheStatus {
        let status: DockerRegistryCache.Status
        if runtimeReady {
            status = await cache.status()
        } else {
            let bytes = DockerRegistryCache.dataBytes(at: cache.dataDirectory)
            status = DockerRegistryCache.Status(
                exists: false, running: false, address: nil, dataBytes: bytes,
                dataDirectory: cache.dataDirectory.path, problem: "the container runtime is not ready",
                storage: bytes == nil ? nil : DockerRegistryCacheStorage.scan(cache.dataDirectory))
        }
        let storage = status.storage
        return DoctorReport.RegistryCacheStatus(
            running: status.running, address: status.address, dataBytes: status.dataBytes,
            dataDirectory: status.dataDirectory, problem: status.problem, ttl: status.ttl,
            wantedTTL: status.wantedTTL ?? cache.ttl, brokenEntries: storage?.problems,
            brokenExamples: storage.map { Array(($0.danglingLinks + $0.brokenBlobs + $0.corruptBlobs).prefix(3)) })
    }
}
