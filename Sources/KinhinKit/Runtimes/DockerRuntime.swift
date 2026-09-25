import Foundation

/// Execution runtime backed by Docker: Linux runner containers inside the
/// provider's shared Linux VM (Docker Desktop, OrbStack, or colima). kinhin
/// delegates the VM — it never starts, stops, or configures the provider —
/// and runs one container per job slot (`--cpus`/`--memory` per slot),
/// exactly the slot model the capacity partition counts. Registration reuses
/// the same Linux agent scripts as the Apple-container runtime, executed via
/// `docker exec` (no SSH, no guest IP).
///
/// The toolchain cache mount (`RepoRoute.cacheMount`) bind-mounts the same
/// host cache the VMs and Apple containers use (`docker run -v host:guest`,
/// guest path `/var/kinhin-cache`), and registration scripts get the guarded
/// Linux cache-env exports — so `npm ci`, `go mod download`, `dotnet restore`,
/// and friends hit warm downloads on every provider.
public struct DockerRuntime: Runtime {
    public let id: RuntimeID = .docker

    /// The `docker` CLI runner (injectable for tests).
    let shell: ShellRunning
    /// Linux OCI image baked with the runner agents (`kinhin image prepare --docker`).
    let image: String
    /// vCPUs per runner container.
    let cpus: Int
    /// Memory per runner container (bytes).
    let memoryBytes: Int64
    /// Binary-path override (tests); nil resolves from PATH/well-known paths.
    let binPath: String?
    /// Existence probe for the binary (tests inject a constant; production
    /// checks the filesystem).
    let exists: @Sendable (String) -> Bool
    /// The resolved managed-toolchain selection source (cache envs come from
    /// here when `share_cache` bind-mounts the host cache into containers).
    let toolchainsConfig: @Sendable () -> kinhinConfig.ToolchainsConfig?

    public init(
        shell: ShellRunning = Shell(),
        image: String,
        cpus: Int = 2,
        memoryGB: Int = 4,
        binPath: String? = nil,
        exists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        toolchainsConfig: @escaping @Sendable () -> kinhinConfig.ToolchainsConfig? = { nil }
    ) {
        self.shell = shell
        self.image = image
        self.cpus = cpus
        self.memoryBytes = Int64(memoryGB) * 1_073_741_824
        self.binPath = binPath
        self.exists = exists
        self.toolchainsConfig = toolchainsConfig
    }

    /// Linux-platform selection for cache-env exports in registration
    /// scripts (computed per request from live config). nil = no selection.
    var linuxToolchainSelection: ManagedToolchainSelection? {
        guard let config = toolchainsConfig() else { return nil }
        return ToolchainCatalog.selection(from: config, platform: .linux)
    }

    /// Resolved path of the `docker` CLI. Public so the CLI doctor and the
    /// checklist invoke the same binary the runtime uses.
    public static var resolvedBinaryPath: String {
        if let found = Paths.findExecutable(named: "docker") { return found }
        let candidates = [
            NSHomeDirectory() + "/.docker/bin/docker",  // Docker Desktop's CLI path
            "/usr/local/bin/docker",  // Docker Desktop symlink / colima
            "/opt/homebrew/bin/docker",  // brew-installed CLI
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/usr/local/bin/docker"
    }

    var bin: String { binPath ?? Self.resolvedBinaryPath }

    var memoryLabel: String { "\(memoryBytes / 1_048_576)M" }

    var memoryGBLabel: String { "\(memoryBytes / 1_073_741_824) GB" }

    // MARK: - Health

    public func health() async -> RuntimeHealth {
        let resolved = binPath ?? Self.resolvedBinaryPath
        guard exists(resolved) else {
            return .missing(
                tool: "docker",
                fix: "install Docker Desktop (or colima: brew install colima && colima start)"
            )
        }
        // The CLI exists; require the daemon to answer (every command fails
        // opaquely otherwise). One probe covers all three providers.
        let info = try? await run([resolved, "info", "--format", "{{.ServerVersion}}"])
        guard let info, info.succeeded,
            !info.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .broken("the Docker daemon is not reachable — start Docker Desktop (or: colima start)")
        }
        return .ready
    }

    // MARK: - Provision

    public func provision(id: String, route: RepoRoute) async throws {
        // Idempotent: a container from a previous engine run may still exist.
        if try await containerIDs(all: true).contains(id) {
            Log.info(id, "container already exists; starting it (recovery)")
            _ = try await run([bin, "start", id])
            return
        }
        Log.info(id, "starting Linux container from \(image) (\(cpus) vCPU, \(memoryGBLabel), linux/arm64)")
        var argv = [bin, "run", "--detach"]
        // Opt-in shared cache: bind-mount the host toolchain cache into the
        // container (`docker run -v host:guest`) so per-job installs reuse
        // warm downloads. Best-effort: create the host dir first so a fresh
        // install cannot fail the run.
        if route.cacheMount {
            try? FileManager.default.createDirectory(at: Paths.toolchainCache, withIntermediateDirectories: true)
            argv += ["--volume", ToolchainCacheMount.volumeSpec(host: Paths.toolchainCache.path)]
        }
        argv += [
            "--name", id,
            "--cpus", String(cpus),
            "--memory", memoryLabel,
            "--platform", "linux/arm64",
            "--rm",  // agent exit removes the container: belt + suspenders
            image,
            "/bin/bash", "-lc", "while true; do sleep 3600; done",
        ]
        _ = try await run(argv)
    }

    // MARK: - Registration

    /// The bootstrap script (same forge scripts the Apple-container runtime
    /// uses — Linux agent paths). Executed inside the container by the
    /// engine via `execRegistration`.
    public func registrationScript(
        forge: Forge, token: String, name: String,
        runnerCount: Int, route: RepoRoute, labels: [String]?
    ) async throws -> String {
        // Opt-in shared cache: point the selected ecosystems' caches at the
        // bind-mounted host cache so per-job installs reuse warm downloads.
        // Exports are guarded no-ops when the mount is absent. Linux
        // platform: macOS-only entries (brew, fvm, CocoaPods) never appear.
        let cachePrefix: String
        if route.cacheMount, let selection = linuxToolchainSelection {
            cachePrefix =
                RunnerBootstrap.cacheEnvExports(
                    cacheEnvs: selection.cacheEnvs,
                    mountPath: ToolchainCacheMount.linuxGuestPath
                ) + "\n\n"
        } else {
            cachePrefix = ""
        }
        switch forge.credentials {
        case .github:
            return cachePrefix
                + RunnerBootstrap.linuxGitHubRegistrationScript(
                    configureURL: forge.registrationURL(),
                    token: token,
                    labels: labels ?? forge.labels,
                    ephemeral: route.ephemeral,
                    name: name,
                    runnerCount: runnerCount
                )
        case .gitea:
            guard let giteaForge = forge as? GiteaForge else {
                throw RuntimeWatchError.registrationFailed(vm: name, stderr: "gitea forge misconfigured")
            }
            return cachePrefix
                + RunnerBootstrap.linuxGiteaRegistrationScript(
                    instance: giteaForge.registrationURL(),
                    token: giteaForge.registrationToken,
                    labels: forge.labels,
                    name: name,
                    runnerCount: runnerCount
                )
        }
    }

    /// Runs a script inside the running container (`docker exec`), which
    /// surfaces the script's exit status directly.
    public func execScript(_ id: String, _ script: String, timeout: TimeInterval = 600) async throws -> ShellResult {
        try await run([bin, "exec", id, "/bin/bash", "-lc", script], timeout: timeout)
    }

    public func awaitReady(id: String, timeout: TimeInterval) async throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if try await containerIDs(all: false).contains(id) {
                return nil  // exec transport: no address to dial
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw RuntimeWatchError.registrationTimeout(vm: id)
    }

    public func execRegistration(_ id: String, ip: String?, _ script: String, timeout: TimeInterval) async throws
        -> ShellResult
    {
        try await execScript(id, script, timeout: timeout)
    }

    // MARK: - Watch

    public func watchExit(id: String, forge: Forge, runnerCount: Int, route: RepoRoute) async throws {
        // Engine-owned watch (forge-side runner lists): identical semantics
        // for containers because agents register under the same names.
    }

    // MARK: - Teardown

    public func teardown(id: String) async {
        // --rm already removes the container on agent exit; belt + suspenders.
        _ = try? await run([bin, "rm", "--force", id])
    }

    // MARK: - Internals

    /// All container ids known to the CLI (running + stopped) — also the
    /// recovery path's instance enumeration.
    public func existingInstanceIDs() async -> [String] {
        (try? await containerIDs(all: true)) ?? []
    }

    public func containerIDs(all: Bool) async throws -> [String] {
        let argv: [String] =
            all
            ? [bin, "ps", "--all", "--quiet"]
            : [bin, "ps", "--quiet"]
        let result = try await run(argv)
        guard result.succeeded else { return [] }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Local list of image references (for the checklist's image-present
    /// row and the doctor).
    public func localImageNames() async -> [String] {
        let result = try? await run([bin, "images", "--format", "{{.Repository}}:{{.Tag}}"])
        guard let result, result.succeeded else { return [] }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func run(_ argv: [String], timeout: TimeInterval = 120) async throws -> ShellResult {
        try await shell.run(argv, cwd: nil, timeout: timeout)
    }
}
