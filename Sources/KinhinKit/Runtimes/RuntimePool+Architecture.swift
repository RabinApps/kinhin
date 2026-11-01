import Foundation

// MARK: - Which architectures a runtime pool serves

extension RuntimePool {
    /// Whether some runner of this pool registers with `x64`: its own labels
    /// say so, or, for Apple container, one of its named pools is amd64.
    func servesX64(config: RuntimeConfigModel) -> Bool {
        let x64 = LinuxPlatform.amd64.runnerLabel
        if labels.contains(where: { $0.lowercased() == x64 }) { return true }
        return runtime == .appleContainer && config.containerPools.entries.contains { $0.platform == .amd64 }
    }
}
