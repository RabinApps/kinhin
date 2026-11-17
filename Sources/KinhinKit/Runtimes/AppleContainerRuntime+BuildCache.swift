import Foundation

// AppleContainerRuntime — a Docker runner whose dockerd keeps its state between jobs (`docker: { build_cache: true }`,
// `DockerBuildCacheVolumes`): the runner starts with a volume of its own at /var/lib/docker, and stops dockerd before
// it is deleted so the volume is left consistent for the next runner.
extension AppleContainerRuntime {
    /// How long teardown waits for dockerd to stop before the container is deleted anyway.
    static let dockerStopSeconds = 20

    /// Starts runner `id` with a build cache volume, or without one when none can be had (logged by the lease).
    func provisionWithBuildCache(id: String, route: RepoRoute, volumes: DockerBuildCacheVolumes) async throws {
        let volume = await volumes.lease(for: id, pool: poolName)
        do {
            try await cli.provision(
                id: id, route: route, extraRunFlags: volume.map(DockerBuildCacheVolumes.runFlags(volume:)) ?? [])
        } catch {
            await volumes.provisioned(id)
            throw error
        }
        await volumes.provisioned(id)
    }

    /// Stops the runner's containers and dockerd so the volume's image store and BuildKit cache are written out
    /// before the container is deleted. Best effort: a runner that does not answer is deleted all the same, and
    /// dockerd recovers its data root at the next start.
    func stopDockerCleanly(_ id: String) async {
        do {
            let result = try await cli.exec(
                id, Self.dockerStopScript(seconds: Self.dockerStopSeconds),
                timeout: TimeInterval(Self.dockerStopSeconds + 15))
            if !result.succeeded { Log.info(id, "dockerd did not stop cleanly: \(result.failureExcerpt)") }
        } catch {
            Log.info(id, "could not stop dockerd before removing the runner: \(error.localizedDescription)")
        }
    }

    /// Stops every container, then dockerd (SIGTERM, waiting up to `seconds`), then flushes the file system.
    static func dockerStopScript(seconds: Int) -> String {
        """
        running="$(docker ps -q 2>/dev/null)"
        [ -z "$running" ] || docker stop -t 5 $running >/dev/null 2>&1 || true
        pid="$(cat /var/run/docker.pid 2>/dev/null)"
        if [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null; then
          for _ in $(seq 1 \(seconds)); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        fi
        sync
        """
    }
}
