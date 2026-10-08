import Foundation

/// The Docker-compatible CLI both Linux container runtimes drive — `docker`
/// and Apple's `container` take the same run/exec/start flags and differ only
/// in a few verbs (the `Dialect`). `DockerRuntime` and `AppleContainerRuntime`
/// keep their health probes and public surface; everything a runner
/// container goes through (provision, registration, readiness, teardown,
/// enumeration) lives here once.
struct LinuxContainerCLI: Sendable {
    /// Where the two CLIs differ.
    struct Dialect: Sendable {
        /// Log tag ("docker", "container").
        let tag: String
        /// Lists containers: `docker ps` / `container list`.
        let listVerb: String
        /// Removes a container: `docker rm` / `container delete`.
        let removeVerb: String
        /// Flags that make the list command print one container *name* per line
        /// (`docker ps --quiet` prints ids, which never match the `kinhin-` names).
        let listNameArguments: [String]
        /// Lists local image references, one per line.
        let imageListArguments: [String]
        /// Removes one local image (`docker image rm` / `container image delete`).
        let imageRemoveArguments: [String]
        /// Extra `run` flags (Docker's `--platform`).
        let runFlags: [String]
        /// Shown in the provision log line (Docker's platform).
        let shapeNote: String?
    }

    let shell: ShellRunning
    let bin: String
    let dialect: Dialect
    /// Linux image baked with the runner agents.
    let image: String
    let cpus: Int
    let memoryBytes: Int64

    var memoryLabel: String { "\(memoryBytes / 1_048_576)M" }

    // MARK: - Provision

    /// Starts the runner container (or restarts an existing one: recovery).
    func provision(id: String, route: RepoRoute) async throws {
        if try await containerIDs(all: true).contains(id) {
            Log.info(id, "container already exists; starting it (recovery)")
            try await require(run([bin, "start", id]), "starting container \(id)")
            return
        }
        let shape = ["\(cpus) vCPU", "\(memoryBytes / 1_073_741_824) GB"] + [dialect.shapeNote].compactMap { $0 }
        Log.info(id, "starting Linux container from \(image) (\(shape.joined(separator: ", ")))")
        var argv = [bin, "run", "--detach"]
        // Opt-in shared cache: bind-mount the host toolchain cache so per-job
        // installs reuse warm downloads. Best-effort: create the host dir
        // first so a fresh install cannot fail the run.
        if route.cacheMount {
            bestEffort(dialect.tag, "creating the toolchain cache directory") {
                try FileManager.default.createDirectory(at: Paths.toolchainCache, withIntermediateDirectories: true)
            }
            argv += ["--volume", ToolchainCacheMount.volumeSpec(host: Paths.toolchainCache.path)]
        }
        argv += ["--name", id, "--cpus", String(cpus), "--memory", memoryLabel] + dialect.runFlags
        argv += [
            "--rm",  // a container that stops (crash, engine kill) removes itself
            image,
            "/bin/bash", "-lc", "while true; do sleep 3600; done",
        ]
        try await require(run(argv), "starting a container from \(image)")
    }

    // MARK: - Registration

    /// The Linux bootstrap script for the forge, run inside the container.
    func registrationScript(
        forge: Forge, token: String, runnerTokens: [String: String], name: String,
        runnerCount: Int, route: RepoRoute, labels: [String]?
    ) throws -> String {
        // Linux platform: macOS-only entries (brew, fvm, CocoaPods) never appear.
        let selection = route.toolchains.map { ToolchainCatalog.selection(from: $0, platform: .linux) }
        let cachePrefix = RunnerBootstrap.cachePrefix(
            mounted: route.cacheMount, selection: selection, mountPath: ToolchainCacheMount.linuxGuestPath)
        let request = RegistrationRequest(
            forge: forge, token: token, runnerTokens: runnerTokens, name: name, runnerCount: runnerCount,
            route: route, labels: labels)
        return cachePrefix
            + (try forge.credentials.forge.descriptor.registrationScript(for: .linuxContainer, request))
    }

    /// Runs a script inside the running container (`exec`), which surfaces
    /// the script's exit status directly — the exec analogue of SSH.
    func exec(_ id: String, _ script: String, timeout: TimeInterval = 600) async throws -> ShellResult {
        // `-i` + a login shell reading stdin: the script (registration tokens
        // included) stays out of the docker/container CLI's argv.
        try await shell.run(
            [bin, "exec", "-i", id, "/bin/bash", "-ls"], input: Data(script.utf8), cwd: nil, timeout: timeout)
    }

    /// Polls until the container is running so `exec` can proceed.
    func awaitRunning(_ id: String, timeout: TimeInterval, pollInterval: TimeInterval = 1) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if try await containerIDs(all: false).contains(id) { return }
            try await Task.sleep(for: .seconds(pollInterval))
        }
        throw RuntimeWatchError.registrationTimeout(vm: id)
    }

    // MARK: - Teardown

    /// Removes the container. `--rm` usually got there first, so an already
    /// missing container is fine; any other failure is thrown.
    func teardown(id: String) async throws {
        do {
            let result = try await run([bin, dialect.removeVerb, "--force", id])
            let gone =
                result.stderr.localizedCaseInsensitiveContains("no such container")
                || result.stderr.localizedCaseInsensitiveContains("not found")
            if !gone { try require(result, "removing container \(id)") }
        } catch is CancellationError {
            return
        } catch {
            Log.warn(id, "removing container failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Enumeration

    /// Container ids known to the CLI (`all`: stopped ones too). Throws when
    /// the CLI fails: a dead daemon must not read as "no containers".
    func containerIDs(all: Bool) async throws -> [String] {
        let argv = [bin, dialect.listVerb] + (all ? ["--all"] : []) + dialect.listNameArguments
        let result = try await run(argv)
        try require(result, "listing containers")
        return result.outputLines
    }

    /// Running, stopped (exited but not removed) or gone. A `--rm` container
    /// that exited is removed, so it reads as gone.
    func state(id: String) async throws -> InstanceState {
        if try await containerIDs(all: false).contains(id) { return .running }
        return try await containerIDs(all: true).contains(id) ? .stopped : .gone
    }

    /// Local image references (the checklist's image row and the doctor);
    /// empty, with a warning, when the CLI can't list them.
    func localImageNames() async -> [String] {
        do {
            let result = try await run([bin] + dialect.imageListArguments)
            try require(result, "listing images")
            return result.outputLines
        } catch {
            Log.warn(dialect.tag, "could not list images: \(error.localizedDescription)")
            return []
        }
    }

    /// Disk usage of local images in whole GB, from the CLI's own size
    /// listing (`arguments`) parsed by the runtime (`parse`: the two CLIs
    /// print different formats). Empty when the CLI can't say: the inventory
    /// rows then read "—", never a wrong number.
    func localImageSizes(arguments: [String], parse: (String) -> [String: Int]) async -> [String: Int] {
        do {
            let result = try await run([bin] + arguments)
            guard result.succeeded else { return [:] }
            return parse(result.stdout)
        } catch {
            Log.warn(dialect.tag, "could not list image sizes: \(error.localizedDescription)")
            return [:]
        }
    }

    /// A byte count as whole GB, rounded to nearest but never 0 for an image
    /// that exists (a row that says "0 GB" reads as broken, not small).
    static func wholeGigabytes(bytes: Double) -> Int {
        max(1, Int((bytes / 1_000_000_000).rounded()))
    }

    /// Removes one local image reference. An image that is already gone is
    /// success — deleting is idempotent, like `teardown`.
    func deleteImage(_ name: String) async throws {
        let result = try await run([bin] + dialect.imageRemoveArguments + [name])
        let gone =
            result.stderr.localizedCaseInsensitiveContains("no such image")
            || result.stderr.localizedCaseInsensitiveContains("not found")
            || result.stderr.localizedCaseInsensitiveContains("does not exist")
        guard result.succeeded || gone else {
            throw ContainerManagerError.commandFailed(
                what: "\(dialect.tag): removing image \(name)", stderr: result.failureExcerpt)
        }
    }

    func run(_ argv: [String], timeout: TimeInterval = 120) async throws -> ShellResult {
        try await shell.run(argv, cwd: nil, timeout: timeout)
    }

    private func require(_ result: ShellResult, _ what: String) throws {
        guard result.succeeded else {
            throw ContainerManagerError.commandFailed(what: "\(dialect.tag): \(what)", stderr: result.stderr)
        }
    }
}
