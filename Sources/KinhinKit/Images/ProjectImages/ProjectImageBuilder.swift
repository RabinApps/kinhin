import Foundation

/// Builds, tracks and prunes the derived per-project tart images. Bakes run
/// one at a time (each boots a scratch VM and is disk-heavy) and a request
/// for an image that is already baking is a no-op, so a queue of jobs for
/// one repo triggers a single bake. Callers never wait on a bake: `request`
/// returns immediately and the job runs on the global image meanwhile.
actor ProjectImageBuilder {
    enum Availability: Sendable, Equatable {
        case ready(name: String)
        case building(name: String)
        /// A bake failed recently; retried after `retryAfter`.
        case failed(name: String, reason: String)
    }

    typealias Bake = @Sendable (ImagePreparer.Options) async throws -> Void
    /// Told once per finished bake: the image name, how long it took, and whether it succeeded. Not called
    /// for a bake cancelled by shutdown, which is neither.
    typealias BakeObserver = @Sendable (_ image: String, _ seconds: Double, _ succeeded: Bool) -> Void

    /// How long a failed bake is left alone before the next attempt.
    static let retryAfter: TimeInterval = 600
    /// Derived images kept when `max_project_images:` is unset.
    static let defaultMaxImages = 8

    private let tart: TartControlling
    private let store: ProjectImageStore
    /// The global image every derived image is cloned from.
    private let baseImage: String
    private let bake: Bake
    private let onBake: BakeObserver?
    private let now: @Sendable () -> Date

    private var building: Set<String> = []
    /// Images seen on disk recently, so a queue of jobs does not run
    /// `tart list` once per job per poll.
    private var seenReady: [String: Date] = [:]
    private static let readyTTL: TimeInterval = 60
    private var failures: [String: (reason: String, at: Date)] = [:]
    private var tail: Task<Void, Never>?

    init(
        tart: TartControlling, store: ProjectImageStore, baseImage: String, ssh: SSHExecuting = SSHExecutor(),
        bake: Bake? = nil, onBake: BakeObserver? = nil, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.onBake = onBake
        self.tart = tart
        self.store = store
        self.baseImage = baseImage
        self.now = now
        self.bake =
            bake ?? { options in
                try await ImagePreparer(tart: tart, ssh: ssh).run(options)
            }
    }

    /// The derived image name for a toolchain set.
    func imageName(for toolchains: KinhinConfig.ToolchainsConfig, shareCache: Bool = false) -> String {
        ToolchainImageKey.imageName(base: baseImage, key: imageKey(toolchains, shareCache: shareCache))
    }

    private func imageKey(_ toolchains: KinhinConfig.ToolchainsConfig, shareCache: Bool) -> String {
        ToolchainImageKey.make(toolchains: toolchains, base: baseImage, platform: .macOS, shareCache: shareCache)
    }

    /// Returns the image when it exists, otherwise starts a bake (unless one
    /// is running or failed recently) and reports its state. A `tart list`
    /// that fails is `.failed` with that reason, never "not built yet": a
    /// bake over a ready image would be wasted work at best. Throws only
    /// `CancellationError`.
    func request(toolchains: KinhinConfig.ToolchainsConfig, shareCache: Bool) async throws -> Availability {
        let key = imageKey(toolchains, shareCache: shareCache)
        let name = ToolchainImageKey.imageName(base: baseImage, key: key)
        if building.contains(name) { return .building(name: name) }
        let present: Bool
        do {
            present = try await exists(name)
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            Log.warn("images", "could not list tart images: \(error.localizedDescription)")
            return .failed(name: name, reason: "could not list tart images: \(error.localizedDescription)")
        }
        if present, store.record(named: name) != nil {
            store.touch(name, now: now())
            return .ready(name: name)
        }
        if let failure = failures[name], now().timeIntervalSince(failure.at) < Self.retryAfter {
            return .failed(name: name, reason: failure.reason)
        }
        start(name: name, key: key, toolchains: toolchains, shareCache: shareCache)
        return .building(name: name)
    }

    /// Waits for every queued bake (tests and the CLI's eager prepare).
    func waitForBakes() async {
        await tail?.value
    }

    private func start(name: String, key: String, toolchains: KinhinConfig.ToolchainsConfig, shareCache: Bool) {
        building.insert(name)
        let previous = tail
        let bake = self.bake
        let onBake = self.onBake
        let base = baseImage
        tail = Task { [weak self] in
            await previous?.value
            var options = ImagePreparer.Options(
                source: base, target: name, toolchains: toolchains, shareCache: shareCache,
                cacheScope: shareCache ? key : nil)
            options.provisionScriptPath = nil
            let started = ContinuousClock.now
            func elapsed() -> Double { (ContinuousClock.now - started) / .seconds(1) }
            do {
                Log.info("images", "baking project image \(name) from \(base)")
                try await bake(options)
                onBake?(name, elapsed(), true)
                await self?.finished(name: name, key: key, toolchains: toolchains, shareCache: shareCache, error: nil)
            } catch {
                if !(error is CancellationError) { onBake?(name, elapsed(), false) }
                await self?.finished(name: name, key: key, toolchains: toolchains, shareCache: shareCache, error: error)
            }
        }
    }

    private func finished(
        name: String, key: String, toolchains: KinhinConfig.ToolchainsConfig, shareCache: Bool, error: Error?
    ) {
        building.remove(name)
        if let error {
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.warn("images", "baking project image \(name) failed: \(reason)")
            failures[name] = (reason, now())
            return
        }
        failures[name] = nil
        seenReady[name] = nil
        let stamp = now()
        store.upsert(
            ProjectImageRecord(
                name: name, key: key, base: baseImage, summary: Self.summary(of: toolchains), createdAt: stamp,
                lastUsedAt: stamp, toolchains: .init(toolchains), shareCache: shareCache))
        Log.info("images", "project image \(name) is ready")
    }

    private func exists(_ name: String) async throws -> Bool {
        if let seen = seenReady[name], now().timeIntervalSince(seen) < Self.readyTTL { return true }
        let found = try await tart.list().contains { $0.name == name }
        seenReady[name] = found ? now() : nil
        return found
    }

    /// Deletes derived images beyond the limits; images a live VM was cloned
    /// from (`inUse`) are kept. Returns the names removed.
    @discardableResult
    func prune(maxImages: Int, maxAgeDays: Int, inUse: Set<String>) async -> [String] {
        let doomed = store.pruneCandidates(
            maxImages: maxImages, maxAgeDays: maxAgeDays, protected: inUse.union(building), now: now())
        var removed: [String] = []
        for name in doomed {
            do {
                try await tart.delete(name: name)
                seenReady[name] = nil
                store.remove(name: name)
                removed.append(name)
                Log.info("images", "pruned project image \(name)")
            } catch {
                Log.warn("images", "could not delete project image \(name): \(error.localizedDescription)")
            }
        }
        return removed
    }

    static func summary(of toolchains: KinhinConfig.ToolchainsConfig) -> String {
        ((toolchains.specs ?? []) + (toolchains.stacks ?? []).map { "stack:\($0)" }).joined(separator: ", ")
    }
}
