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
    /// Linux image baked with the runner agents (`orchard image prepare`).
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

    public init(shell: ShellRunning = Shell(),
                image: String = "orchard-ci-linux",
                cpus: Int = 4,
                memoryGB: Int = 8,
                binPath: String? = nil,
                exists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.shell = shell
        self.image = image
        self.cpus = cpus
        self.memoryBytes = Int64(memoryGB) * 1_073_741_824
        self.binPath = binPath
        self.exists = exists
    }

    /// Resolved path of the `container` CLI (the Homebrew cask installs to
    /// /usr/local/bin; PATH and common prefixes are honored). Public so the
    /// CLI doctor and app fix-actions invoke the same binary the runtime uses.
    public static var resolvedBinaryPath: String {
        Paths.findExecutable(named: "container") ?? "/usr/local/bin/container"
    }

    /// Resolved path of the `container` CLI.
    var bin: String { binPath ?? Self.resolvedBinaryPath }

    var memoryLabel: String { "\(memoryBytes / 1_048_576)M" }

    var memoryGBLabel: String { "\(memoryBytes / 1_073_741_824) GB" }

    // MARK: - Health

    public func health() async -> RuntimeHealth {
        let resolved = binPath ?? Paths.findExecutable(named: "container")
        guard let resolved, exists(resolved) else {
            return .missing(
                tool: "apple container",
                fix: "brew install --cask container && container system start"
            )
        }
        // The CLI exists; require the host API service to be running
        // (every command fails opaquely without it).
        let status = try? await run([resolved, "system", "status"])
        guard let status, status.succeeded else {
            return .broken("the container system service is not running — start it with: container system start")
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
        Log.info(id, "starting Linux container from \(image) (\(cpus) vCPU, \(memoryGBLabel))")
        _ = try await run([
            bin, "run", "--detach",
            "--name", id,
            "--cpus", String(cpus),
            "--memory", memoryLabel,
            "--rm",  // agent exit removes the container: belt + suspenders
            image,
            "/bin/bash", "-lc", "while true; do sleep 3600; done",
        ])
    }

    // MARK: - Registration

    /// The bootstrap script (same forge scripts the VMs use — Linux agent
    /// paths). Executed inside the container by the engine via execScript.
    public func registrationScript(forge: Forge, token: String, name: String,
                                   runnerCount: Int, route: RepoRoute, labels: [String]?) async throws -> String {
        switch forge.credentials {
        case .github:
            return RunnerBootstrap.linuxGitHubRegistrationScript(
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
            return RunnerBootstrap.linuxGiteaRegistrationScript(
                instance: giteaForge.registrationURL(),
                token: giteaForge.registrationToken,
                labels: forge.labels,
                name: name,
                runnerCount: runnerCount
            )
        }
    }

    /// Runs a script inside a running container (`container exec`), which
    /// surfaces the script's exit status directly — the container analogue
    /// of the SSH transport. Also the runtime's `execRegistration` impl.
    public func execScript(_ id: String, _ script: String, timeout: TimeInterval = 600) async throws -> ShellResult {
        try await run([bin, "exec", id, "/bin/bash", "-lc", script], timeout: timeout)
    }

    public func awaitReady(id: String, timeout: TimeInterval) async throws -> String? {
        _ = try await awaitRunning(id, timeout: timeout)
        return nil
    }

    public func execRegistration(_ id: String, ip: String?, _ script: String, timeout: TimeInterval) async throws -> ShellResult {
        try await execScript(id, script, timeout: timeout)
    }

    /// Ids of all known containers (running + stopped) — the recovery path
    /// enumerates instances through the runtime, no per-runtime branch.
    public func existingInstanceIDs() async -> [String] {
        (try? await containerIDs(all: true)) ?? []
    }

    /// The boot-wait analogue of `tart.ip`: polls until the container is
    /// running so `container exec` can proceed. Returns the container id
    /// (the engine stores it in the record's ip field; there is no IP).

    // MARK: - Watch

    public func watchExit(id: String, forge: Forge, runnerCount: Int, route: RepoRoute) async throws {
        // Engine-owned watch (forge-side runner lists): identical semantics
        // for containers because agents register under the same names.
        // Nothing to do at the runtime layer — same contract as TartRuntime.
    }

    /// Poll `container list` until the named container is running (or throw).
    public func awaitRunning(_ id: String, timeout: TimeInterval, pollInterval: TimeInterval = 1) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if try await containerIDs(all: false).contains(id) {
                return id
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw RuntimeWatchError.registrationTimeout(vm: id)
    }

    // MARK: - Teardown

    public func teardown(id: String) async {
        // --rm already removes the container on agent exit; belt + suspenders.
        _ = try? await run([bin, "delete", "--force", id])
    }

    // MARK: - Internals

    /// All container ids known to the CLI (running + stopped).
    public func containerIDs(all: Bool) async throws -> [String] {
        let argv: [String] = all
            ? [bin, "list", "--all", "--quiet"]
            : [bin, "list", "--quiet"]
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
        let result = try? await run([bin, "image", "list", "--quiet"])
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

public enum RuntimeWatchError: LocalizedError {
    case registrationFailed(vm: String, stderr: String)
    case registrationTimeout(vm: String)

    public var errorDescription: String? {
        switch self {
        case .registrationFailed(let vm, let stderr):
            return "runner registration failed in \(vm): \(stderr.prefix(300))"
        case .registrationTimeout(let vm):
            return "runner in \(vm) did not start/register within the boot timeout"
        }
    }
}
