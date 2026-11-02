import Foundation

// AppleContainerRuntime — pointing a Docker runner's dockerd at kinhin's Docker Hub cache (`DockerRegistryCache`).
//
// Apple container gives the cache a new address on every start, publishing a port on the gateway resets connections,
// and containers get no DNS names, so the mirror cannot be baked into the image: at each Docker runner's registration,
// before dockerd starts, kinhin asks the cache for its current address, checks the runner can reach it, reads the
// image's /etc/docker/daemon.json, and merges the mirror into it. Every failure on this path is logged and skipped:
// the runner still registers, and its dockerd pulls from Docker Hub directly. Only cancellation propagates.
extension AppleContainerRuntime {
    /// Printed before the image's daemon.json, so a login shell's own output above it is never read as the file.
    static let daemonJSONMarker = "--- kinhin: /etc/docker/daemon.json ---"

    /// The probe's exit status when the cache does not answer from inside the runner.
    static let cacheUnreachableExitCode: Int32 = 3

    /// How long a runner waits for the cache to answer (under the probe's exec timeout, `cacheProbeTimeout`): a cache
    /// that has just started refuses connections until the registry listens.
    static let cacheReachabilitySeconds = 20
    static let cacheProbeTimeout: TimeInterval = 30

    /// A bash command that succeeds once `address`:5000 accepts a TCP connection, retrying every second for up to
    /// `seconds` (bash's `/dev/tcp`, so the image needs nothing extra; exits 124 when time runs out).
    static func cacheReachabilityScript(address: String, seconds: Int = cacheReachabilitySeconds) -> String {
        "timeout \(seconds) bash -c 'until : < /dev/tcp/\(address)/\(DockerRegistryCache.port); do sleep 1; done' "
            + "2>/dev/null"
    }

    /// Run in the runner before registration: waits for the cache (exit `cacheUnreachableExitCode` when it never
    /// answers), then prints the marker and the image's daemon.json (nothing after the marker when there is none).
    static func cacheProbeScript(address: String, seconds: Int = cacheReachabilitySeconds) -> String {
        """
        if ! \(cacheReachabilityScript(address: address, seconds: seconds)); then
          echo "kinhin: the Docker Hub cache at \(address):\(DockerRegistryCache.port) did not answer within \(seconds) s" >&2
          exit \(cacheUnreachableExitCode)
        fi
        echo '\(daemonJSONMarker)'
        if [ -e /etc/docker/daemon.json ]; then cat /etc/docker/daemon.json; fi
        """
    }

    /// The text after the marker line in the probe's output; nil when the marker is missing.
    static func daemonJSON(fromProbeOutput output: String) -> String? {
        let lines = output.components(separatedBy: "\n")
        guard let marker = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == daemonJSONMarker })
        else { return nil }
        return lines[(marker + 1)...].joined(separator: "\n")
    }

    /// The daemon.json runner `id` should start dockerd with: the image's own file with the cache's mirror merged in.
    /// nil when this pool does not use the cache, and on every failure (logged with the runner id), so the runner
    /// registers with the image's file and pulls from Docker Hub. Throws only `CancellationError`.
    func dockerDaemonJSON(for id: String) async throws -> String? {
        guard docker, let registryCache else { return nil }
        func skip(_ why: String) -> String? {
            Log.warn(id, "not using the Docker Hub cache: \(why); dockerd pulls straight from Docker Hub")
            return nil
        }
        let address: String
        do {
            address = try await registryCache.address()
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return skip(error.localizedDescription)
        }
        let result: ShellResult
        do {
            result = try await cli.exec(id, Self.cacheProbeScript(address: address), timeout: Self.cacheProbeTimeout)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return skip("could not check it from the runner (\(error.localizedDescription))")
        }
        try Task.checkCancellation()
        guard result.succeeded else {
            if result.exitCode == Self.cacheUnreachableExitCode {
                return skip("\(address):\(DockerRegistryCache.port) is not reachable from the runner")
            }
            return skip("could not read /etc/docker/daemon.json (\(result.failureExcerpt))")
        }
        guard let current = Self.daemonJSON(fromProbeOutput: result.stdout) else {
            return skip("the runner printed no /etc/docker/daemon.json")
        }
        let mirror = DockerRegistryCache.mirrorURL(address: address)
        switch DockerDaemonConfig.merging(mirror: mirror, into: current) {
        case .merged(let json):
            Log.info(id, "dockerd pulls through the Docker Hub cache at \(mirror)")
            return json
        case .invalid(let why):
            return skip("the image's /etc/docker/daemon.json is left as it is: \(why)")
        }
    }
}
