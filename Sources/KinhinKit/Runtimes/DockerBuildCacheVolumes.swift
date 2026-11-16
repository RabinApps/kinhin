import Foundation

/// Docker state that outlives a job, for `container.docker` pools with `docker: { build_cache: true }`. Every Docker
/// runner normally starts an empty dockerd and is deleted after its job, so each job builds its images from scratch
/// and pulls everything again. With the build cache on, each runner gets an Apple container volume of its own mounted at
/// `/var/lib/docker`: dockerd's image store and BuildKit's cache live there, and the next runner that gets the volume
/// starts with them.
///
/// One volume belongs to one runner at a time, so two dockerds never write the same BuildKit cache (BuildKit locks its
/// state, and two daemons on one data root corrupt it). A pool has as many volumes as it has had runners at once:
/// a runner takes the lowest-numbered volume of its pool that no container holds (`docker-cache-kinhin-<pool>-<n>`),
/// creating it the first time. A runner's volume is recorded as a container label (`label`), so the holders are read
/// from `container list` and survive a restart of kinhin. A volume is an ext4 disk image (Apple container's default
/// volume format), which dockerd's overlay2 driver needs; a bind-mounted host directory (virtiofs) would not do.
///
/// Every failure here is logged and the runner starts without the cache, exactly as with the option off.
actor DockerBuildCacheVolumes {
    /// The container label naming the volume a runner holds.
    static let label = "kinhin.docker-build-cache"
    /// Where the volume is mounted in the runner: dockerd's data root.
    static let guestPath = "/var/lib/docker"
    /// The size each volume is created with. The disk image is sparse, so it takes only what dockerd writes.
    static let size = "64G"
    /// Volumes start with this prefix. Like the Docker Hub cache, the name does not start with `kinhin`, so nothing
    /// that sweeps runner leftovers by name ever counts it.
    static let prefix = "docker-cache-kinhin-"

    let shell: ShellRunning
    /// Binary-path override (tests); nil resolves like `AppleContainerRuntime`.
    let binPath: String?
    /// Volumes handed out whose runner's container may not be listed yet, by runner id: a second lease in the
    /// meantime must not hand out the same volume.
    private var pending: [String: String] = [:]

    init(shell: ShellRunning = Shell(), binPath: String? = nil) {
        self.shell = shell
        self.binPath = binPath
    }

    var bin: String { binPath ?? AppleContainerRuntime.resolvedBinaryPath }

    /// The name of volume `slot` of `pool` ("" is the section's unnamed pool).
    static func volumeName(pool: String, slot: Int) -> String {
        "\(prefix)\(pool.isEmpty ? "default" : pool)-\(slot)"
    }

    /// The `container run` flags that mount `volume` for a runner and record it on the container.
    static func runFlags(volume: String) -> [String] {
        ["--volume", "\(volume):\(guestPath)", "--label", "\(label)=\(volume)"]
    }

    /// The volume runner `id` of `pool` should start with, created when it is new; nil (logged) when there is none
    /// to give. Call `provisioned(_:)` once the runner's container has been created or failed to be.
    func lease(for id: String, pool: String) async -> String? {
        let held: Set<String>
        do {
            held = try await heldVolumes()
        } catch {
            Log.warn(id, "no Docker build cache this time: could not list containers (\(error.localizedDescription))")
            return nil
        }
        let taken = held.union(pending.filter { $0.key != id }.values)
        var slot = 0
        while taken.contains(Self.volumeName(pool: pool, slot: slot)) { slot += 1 }
        let volume = Self.volumeName(pool: pool, slot: slot)
        do {
            try await ensureVolume(volume, pool: pool)
        } catch {
            Log.warn(id, "no Docker build cache this time: \(error.localizedDescription)")
            return nil
        }
        pending[id] = volume
        Log.info(id, "dockerd keeps its images and build cache in the volume \(volume)")
        return volume
    }

    /// Runner `id`'s container exists now (its label records the volume) or will not: its lease stops being pending.
    func provisioned(_ id: String) {
        pending[id] = nil
    }

    /// The volumes some container (any state) holds, from the label each runner was started with.
    func heldVolumes() async throws -> Set<String> {
        let result = try await shell.run([bin, "list", "--all", "--format", "json"], cwd: nil, timeout: 30)
        guard result.succeeded else {
            throw ContainerManagerError.commandFailed(
                what: "container: listing containers", stderr: result.failureExcerpt)
        }
        return Self.parseHeldVolumes(result.stdout)
    }

    /// `container list --all --format json`: each container's `configuration.labels[label]`.
    static func parseHeldVolumes(_ text: String) -> Set<String> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            // Not JSON (an old CLI, a warning line): no holders are known, so the lowest volume is tried.
            let rows = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [[String: Any]]
        else { return [] }
        return Set(
            rows.compactMap { row in
                let configuration = row["configuration"] as? [String: Any]
                let labels = configuration?["labels"] as? [String: Any] ?? row["labels"] as? [String: Any]
                return labels?[label] as? String
            })
    }

    /// Creates `volume` unless it exists.
    private func ensureVolume(_ volume: String, pool: String) async throws {
        if try await shell.run([bin, "volume", "inspect", volume], cwd: nil, timeout: 30).succeeded { return }
        Log.info("container", "creating the Docker build cache volume \(volume) (\(Self.size), sparse)")
        let result = try await shell.run(
            [
                bin, "volume", "create", "-s", Self.size, "--label", "\(Self.label)=\(pool.isEmpty ? "default" : pool)",
                volume,
            ],
            cwd: nil, timeout: 120)
        guard result.succeeded || result.stderr.localizedCaseInsensitiveContains("exist") else {
            throw ContainerManagerError.commandFailed(
                what: "container: creating the volume \(volume)", stderr: result.failureExcerpt)
        }
    }
}
