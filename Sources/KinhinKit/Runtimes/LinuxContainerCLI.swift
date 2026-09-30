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
        /// Lists local image references, one per line.
        let imageListArguments: [String]
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
    /// Managed toolchains (their cache envs are exported when the route
    /// bind-mounts the host cache).
    let toolchainsConfig: @Sendable () -> KinhinConfig.ToolchainsConfig?

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
            "--rm",  // agent exit removes the container: belt + suspenders
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
        let selection = toolchainsConfig().map { ToolchainCatalog.selection(from: $0, platform: .linux) }
        let cachePrefix = RunnerBootstrap.cachePrefix(
            mounted: route.cacheMount, selection: selection, mountPath: ToolchainCacheMount.linuxGuestPath)
        switch forge.credentials {
        case .github:
            return cachePrefix
                + RunnerBootstrap.linuxGitHubRegistrationScript(
                    configureURL: forge.registrationURL(), token: token, labels: labels ?? forge.labels,
                    ephemeral: route.ephemeral, name: name, runnerCount: runnerCount)
        case .gitea, .forgejo:
            // Forgejo shares Gitea's runner binary and registration flow.
            return cachePrefix
                + RunnerBootstrap.linuxGiteaRegistrationScript(
                    instance: forge.registrationURL(), token: token, labels: forge.labels, name: name,
                    runnerCount: runnerCount)
        case .gitlab:
            return cachePrefix
                + RunnerBootstrap.gitlabRegistrationScript(
                    instance: forge.registrationURL(),
                    runners: try RunnerBootstrap.gitlabRunners(
                        name: name, runnerCount: runnerCount, tokens: runnerTokens),
                    binary: "/opt/gitlab-runner/gitlab-runner",
                    baseDir: "/opt/gitlab-runner")
        }
    }

    /// Runs a script inside the running container (`exec`), which surfaces
    /// the script's exit status directly — the exec analogue of SSH.
    func exec(_ id: String, _ script: String, timeout: TimeInterval = 600) async throws -> ShellResult {
        try await run([bin, "exec", id, "/bin/bash", "-lc", script], timeout: timeout)
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
    /// missing container is fine; any other failure is logged.
    func teardown(id: String) async {
        await bestEffortAsync(id, "removing container") {
            let result = try await run([bin, dialect.removeVerb, "--force", id])
            let gone =
                result.stderr.localizedCaseInsensitiveContains("no such container")
                || result.stderr.localizedCaseInsensitiveContains("not found")
            if !gone { try require(result, "removing container \(id)") }
        }
    }

    // MARK: - Enumeration

    /// Container ids known to the CLI (`all`: stopped ones too). Throws when
    /// the CLI fails: a dead daemon must not read as "no containers".
    func containerIDs(all: Bool) async throws -> [String] {
        let argv = [bin, dialect.listVerb] + (all ? ["--all"] : []) + ["--quiet"]
        let result = try await run(argv)
        try require(result, "listing containers")
        return result.outputLines
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

    func run(_ argv: [String], timeout: TimeInterval = 120) async throws -> ShellResult {
        try await shell.run(argv, cwd: nil, timeout: timeout)
    }

    private func require(_ result: ShellResult, _ what: String) throws {
        guard result.succeeded else {
            throw ContainerManagerError.commandFailed(what: "\(dialect.tag): \(what)", stderr: result.stderr)
        }
    }
}
