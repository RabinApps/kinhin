import Foundation

/// Execution runtime backed by Apple's `container` CLI
/// (github.com/apple/container): every runner is a lightweight Linux
/// micro-VM on Apple silicon — stronger isolation than a shared Docker VM
/// (one microVM per container) with far less overhead than a full Tart
/// macOS VM. Registration runs inside the container via `container exec`
/// (no SSH, no guest IP); the engine's forge-side ephemeral watches
/// (GitHub deregistration, Gitea idle grace) apply unchanged because the
/// agents register with the forges under the same naming scheme.
public struct AppleContainerRuntime: Runtime {
    public let id: RuntimeID = .appleContainer

    /// The `container` binary runner (injectable for tests).
    let shell: ShellRunning
    /// Linux image baked with the runner agents (`kinhin image prepare`).
    let image: String
    /// vCPUs per runner container.
    let cpus: Int
    /// Memory per runner container (bytes).
    let memoryBytes: Int64
    /// Binary-path override (tests); nil resolves from PATH/brew prefixes.
    let binPath: String?
    /// Existence probe for the binary (tests inject a constant; production
    /// checks the filesystem).
    let exists: @Sendable (String) -> Bool
    /// The resolved managed-toolchain selection source (cache envs come from
    /// here when `share_cache` bind-mounts the host cache into containers).
    let toolchainsConfig: @Sendable () -> KinhinConfig.ToolchainsConfig?

    public init(
        shell: ShellRunning = Shell(),
        image: String = "kinhin-ci-linux",
        cpus: Int = 4,
        memoryGB: Int = 8,
        binPath: String? = nil,
        exists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        toolchainsConfig: @escaping @Sendable () -> KinhinConfig.ToolchainsConfig? = { nil }
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

    /// Resolved path of the `container` CLI (the Homebrew cask installs to
    /// /usr/local/bin; PATH and common prefixes are honored). Public so the
    /// CLI doctor and app fix-actions invoke the same binary the runtime uses.
    public static var resolvedBinaryPath: String {
        Paths.findExecutable(named: "container") ?? "/usr/local/bin/container"
    }

    /// Resolved path of the `container` CLI.
    var bin: String { binPath ?? Self.resolvedBinaryPath }

    /// The shared container-CLI driver in Apple `container`'s dialect.
    var cli: LinuxContainerCLI {
        LinuxContainerCLI(
            shell: shell, bin: bin,
            dialect: .init(
                tag: "container", listVerb: "list", removeVerb: "delete",
                listNameArguments: ["--quiet"], imageListArguments: ["image", "list", "--quiet"], runFlags: [],
                shapeNote: nil),
            image: image, cpus: cpus, memoryBytes: memoryBytes, toolchainsConfig: toolchainsConfig)
    }

    // MARK: - Health

    public func health() async -> RuntimeHealth {
        let resolved = binPath ?? Paths.findExecutable(named: "container")
        guard let resolved, exists(resolved) else {
            return .missing(
                tool: "apple container",
                fix: "brew install container && container system start"
            )
        }
        // The CLI exists; require the host API service to be running
        // (every command fails opaquely without it).
        do {
            if try await run([resolved, "system", "status"]).succeeded { return .ready }
        } catch {
            Log.warn("container", "system status probe failed: \(error.localizedDescription)")
        }
        return .broken("the container system service is not running — start it with: container system start")
    }

    // MARK: - Lifecycle (the shared container CLI)

    public func provision(id: String, route: RepoRoute) async throws {
        try await cli.provision(id: id, route: route)
    }

    /// The bootstrap script (same forge scripts the Docker runtime uses —
    /// Linux agent paths), run inside the container via `container exec`.
    public func registrationScript(
        forge: Forge, token: String, runnerTokens: [String: String], name: String,
        runnerCount: Int, route: RepoRoute, labels: [String]?
    ) async throws -> String {
        try cli.registrationScript(
            forge: forge, token: token, runnerTokens: runnerTokens, name: name, runnerCount: runnerCount,
            route: route, labels: labels)
    }

    public func awaitReady(id: String, timeout: TimeInterval) async throws -> String? {
        try await cli.awaitRunning(id, timeout: timeout)
        return nil  // exec transport: no address to dial
    }

    public func execRegistration(_ id: String, ip: String?, _ script: String, timeout: TimeInterval) async throws
        -> ShellResult
    {
        try await cli.exec(id, script, timeout: timeout)
    }

    public func teardown(id: String) async {
        await cli.teardown(id: id)
    }

    /// Ids of all known containers (running + stopped) — the recovery path
    /// enumerates instances through the runtime, no per-runtime branch.
    public func existingInstanceIDs() async throws -> [String] {
        try await cli.containerIDs(all: true)
    }

    /// Local list of image references (for the checklist's image-present
    /// row and the doctor).
    public func localImageNames() async -> [String] {
        await cli.localImageNames()
    }

    func run(_ argv: [String], timeout: TimeInterval = 120) async throws -> ShellResult {
        try await shell.run(argv, cwd: nil, timeout: timeout)
    }
}

enum RuntimeWatchError: LocalizedError {
    case registrationFailed(vm: String, stderr: String)
    case registrationTimeout(vm: String)

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let vm, let stderr):
            return "runner registration failed in \(vm): \(stderr.prefix(300))"
        case .registrationTimeout(let vm):
            return "runner in \(vm) did not start/register within the boot timeout"
        }
    }
}
