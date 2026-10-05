import Foundation

// MARK: - Runtime identity

/// Where runner workloads execute. Stage 1 ships only `.tart`; the Docker
/// and Host implementations land in stages 3–4 of the runtime design
/// (docs/runtime-abstraction-design.md).
public enum RuntimeID: String, Codable, Sendable, CaseIterable {
    case tart
    /// Apple's `container` CLI (github.com/apple/container): Linux runner
    /// workloads in per-container microVMs on Apple silicon. An alternative
    /// to the Docker runtime for Linux jobs — no daemon, no shared VM.
    case appleContainer
    case docker
    case host
}

/// Health of a runtime's prerequisites — same shape as `TartHealth`, so the
/// checklist renders it with existing machinery.
public enum RuntimeHealth: Equatable, Sendable {
    case ready
    case missing(tool: String, fix: String)
    case broken(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// The routing context a runtime needs to provision and register a runner
/// for one repo. Stage 1 carries the current config-driven values; stage 2
/// generalizes it to per-repo routes from the `runtimes:` config section.
public struct RepoRoute: Sendable, Equatable {
    public let repo: String
    public let image: String
    public let ephemeral: Bool
    let bootTimeout: Int
    /// Opt-in per project (`projects[].share_cache`): share the host
    /// toolchain cache into this route's runner VMs via virtiofs, so per-job
    /// installs (`npm ci`, `mise install`, `fvm install`, `dotnet restore`)
    /// hit warm cache. Best-effort — see `ToolchainCacheMount`.
    let cacheMount: Bool
    /// The toolchains baked into `image` (its cache envs are exported in the
    /// registration script when `cacheMount` is on). nil = none baked.
    let toolchains: KinhinConfig.ToolchainsConfig?
    /// The project image key scoping the cache share (nil = the whole cache).
    let cacheScope: String?

    public init(
        repo: String, image: String, ephemeral: Bool, bootTimeout: Int, cacheMount: Bool = false,
        toolchains: KinhinConfig.ToolchainsConfig? = nil, cacheScope: String? = nil
    ) {
        self.repo = repo
        self.image = image
        self.ephemeral = ephemeral
        self.bootTimeout = bootTimeout
        self.cacheMount = cacheMount
        self.toolchains = toolchains
        self.cacheScope = cacheScope
    }

    /// The route for a runner: the fleet's base image, or the derived
    /// per-project `image` (baked with `toolchains`) its record was bound to.
    public static func from(
        config: KinhinConfig, image: String? = nil, toolchains: KinhinConfig.ToolchainsConfig? = nil,
        cacheMount: Bool = false, cacheScope: String? = nil
    ) -> RepoRoute {
        RepoRoute(
            repo: config.repo,
            image: image ?? config.image,
            ephemeral: config.vm.ephemeral,
            bootTimeout: config.vmBootTimeout,
            cacheMount: cacheMount,
            toolchains: toolchains,
            cacheScope: cacheScope
        )
    }
}

// MARK: - Protocol

/// The execution runtime behind the fleet: how workloads are provisioned,
/// how the runner agent is injected, how job completion is watched, and how
/// instances are torn down. Mirrors the engine's lifecycle seams one-to-one
/// so the engine stays runtime-agnostic. Forge (who hands us jobs) and
/// Runtime (where jobs execute) are orthogonal axes.
public protocol Runtime: Sendable {
    var id: RuntimeID { get }

    /// Prerequisite probe (checklist/doctor).
    func health() async -> RuntimeHealth

    /// Provision a fresh runner instance with the given id (clone + boot for
    /// VM runtimes; container start; nothing for host). Must be idempotent
    /// for an id that already exists (recovery path).
    func provision(id: String, route: RepoRoute) async throws

    /// Wait for a provisioned instance to become ready for registration.
    /// Runtimes reachable over a network return the address the registration
    /// transport dials (Tart: the VM's IP for SSH); exec-transport runtimes
    /// (apple container, docker, host) return nil — registration goes
    /// through `execRegistration` with no address.
    func awaitReady(id: String, timeout: TimeInterval) async throws -> String?

    /// Execute the registration script inside the instance. Runtimes whose
    /// `awaitReady` returned an address dial it (SSH); the rest exec locally
    /// inside the instance (container/docker exec).
    func execRegistration(_ id: String, ip: String?, _ script: String, timeout: TimeInterval) async throws
        -> ShellResult

    /// Ids of this runtime's existing instances — the recovery/adopt path
    /// enumerates every configured runtime through this (no per-runtime
    /// branch in the engine). Throws when the runtime can't be asked: a
    /// failed listing must never read as "no instances".
    func existingInstanceIDs() async throws -> [String]

    /// The bootstrap script that turns the provisioned instance into N
    /// registered runners. The engine executes it inside the instance.
    /// `token` is the shared registration token; `runnerTokens` holds the
    /// per-runner credentials of `perRunner` forges (GitLab), keyed by runner
    /// name. `labels` overrides the forge's default label set for the GitHub
    /// branch — the pool's labels in mixed fleets.
    func registrationScript(
        forge: Forge, token: String, runnerTokens: [String: String], name: String,
        runnerCount: Int, route: RepoRoute, labels: [String]?
    ) async throws -> String

    /// Stop and remove the instance. Must be idempotent.
    func teardown(id: String) async
}

extension Runtime {
    /// Shared-token registration (every forge but GitLab).
    func registrationScript(
        forge: Forge, token: String, name: String,
        runnerCount: Int, route: RepoRoute, labels: [String]?
    ) async throws -> String {
        try await registrationScript(
            forge: forge, token: token, runnerTokens: [:], name: name, runnerCount: runnerCount, route: route,
            labels: labels)
    }
}

// MARK: - Tart implementation

/// The original runtime: Tart macOS VMs. Wraps the exact calls the engine
/// made directly before the refactor — behavior-preserving by construction.
struct TartRuntime: Runtime {
    let id: RuntimeID = .tart
    let tart: TartControlling
    let ssh: SSHExecuting
    let bootTimeout: @Sendable () -> Int
    /// How long registration keeps retrying while the guest's sshd is still
    /// coming up, and the pause between attempts. `tart ip` answers as soon
    /// as the VM has a lease — often 20+ seconds before SSH listens (seen
    /// live under softnet).
    let sshReadyWindow: TimeInterval
    let sshRetryInterval: Duration
    /// Pause between TCP probes of the guest's port 22 before ssh is tried.
    let sshProbeInterval: Duration
    /// How long to keep asking the guest agent for a fresh SSH host key before
    /// connecting without host key verification, and the pause between asks.
    let hostKeyWindow: TimeInterval
    let hostKeyInterval: Duration

    /// Cache envs to export in registration scripts when the route mounts
    /// the shared cache, from the toolchains baked into the route's image.
    func cachedToolchainSelection(for route: RepoRoute) -> ManagedToolchainSelection? {
        route.toolchains.map { ToolchainCatalog.selection(from: $0) }
    }

    init(
        tart: TartControlling, bootTimeout: @escaping @Sendable () -> Int, ssh: SSHExecuting = SSHExecutor(),
        sshReadyWindow: TimeInterval = 120, sshRetryInterval: Duration = .seconds(1),
        sshProbeInterval: Duration = .milliseconds(500), hostKeyWindow: TimeInterval = 30,
        hostKeyInterval: Duration = .seconds(2)
    ) {
        self.tart = tart
        self.bootTimeout = bootTimeout
        self.ssh = ssh
        self.sshReadyWindow = sshReadyWindow
        self.sshRetryInterval = sshRetryInterval
        self.sshProbeInterval = sshProbeInterval
        self.hostKeyWindow = hostKeyWindow
        self.hostKeyInterval = hostKeyInterval
    }

    func health() async -> RuntimeHealth {
        let probe = TartHealthProbe()
        let health = await probe.check()
        switch health {
        case .healthy:
            return .ready
        case .missing:
            return .missing(
                tool: "tart", fix: TartHealthProbe.installCommand)
        case .killedOnLaunch:
            return .missing(tool: "tart (notarization rollback)", fix: "roll back to the notarized Cirrus Labs build")
        case .broken(let why):
            return .broken(why)
        }
    }

    func provision(id: String, route: RepoRoute) async throws {
        // A failed list must not read as "no VMs": cloning over an existing
        // one would fail later with a far less useful error.
        let existing = try await tart.list()
        if existing.contains(where: { $0.name == id }) {
            Log.info(id, "VM already exists; reusing (recovery)")
            return
        }
        Log.info(id, "cloning from \(route.image)")
        try await tart.clone(source: route.image, to: id)
        let mounts = route.cacheMount ? [ToolchainCacheMount.tartDirectorySpec(scope: route.cacheScope)] : []
        try await tart.run(name: id, mounts: mounts)
    }

    func awaitReady(id: String, timeout: TimeInterval) async throws -> String? {
        let ip = try await tart.ip(of: id, timeout: timeout)
        // Before any SSH: give this VM its own host key and learn it over the
        // guest agent, so the registration script (runner tokens) only reaches
        // the VM that booted here, not another VM answering on its address.
        try await GuestHostKeyPinning.pin(
            vm: id, tart: tart, ssh: ssh, window: min(hostKeyWindow, timeout), interval: hostKeyInterval)
        return ip
    }

    func execRegistration(_ id: String, ip: String?, _ script: String, timeout: TimeInterval) async throws
        -> ShellResult
    {
        guard let ip, !ip.isEmpty else {
            throw TartError.ipNotFound(vm: id)
        }
        // sshd can lag the DHCP lease; retry only "nothing is listening yet"
        // errors, so a real script failure still fails on the first attempt.
        // A cheap TCP probe of port 22 gates the real ssh: no process is
        // spawned until sshd accepts connections (or the window has run out,
        // when one real attempt produces the error to report).
        //
        // The bring-up window never goes below vm_boot_timeout: that config
        // key promises "seconds a freshly booted VM has to register", and a
        // big image's first boot can leave sshd slow to answer for minutes
        // (seen live: a fresh xcode-image clone timed out at 120s while its
        // replacement registered 2 seconds after boot).
        let deadline = Date().addingTimeInterval(max(sshReadyWindow, TimeInterval(bootTimeout())))
        while true {
            if !(await ssh.isSSHPortOpen(ip: ip)), Date() < deadline {
                try await Task.sleep(for: sshProbeInterval)
                continue
            }
            let result = try await ssh.exec(vm: id, user: "admin", ip: ip, script: script, timeout: timeout)
            if result.succeeded || !Self.sshNotListeningYet(result.stderr) || Date() >= deadline {
                return result
            }
            Log.info(id, "SSH not up yet; retrying")
            try await Task.sleep(for: sshRetryInterval)
        }
    }

    static func sshNotListeningYet(_ stderr: String) -> Bool {
        // "Host is down" is the guest not answering ARP yet, common right after a softnet boot.
        ["Operation timed out", "Connection refused", "No route to host", "Host is down"].contains {
            stderr.contains($0)
        }
    }

    func existingInstanceIDs() async throws -> [String] {
        try await tart.list().map(\.name)
    }

    func registrationScript(
        forge: Forge, token: String, runnerTokens: [String: String], name: String,
        runnerCount: Int, route: RepoRoute, labels: [String]?
    ) async throws -> String {
        // Opt-in shared cache: point the selected ecosystems' caches at the
        // mounted host share so per-job installs reuse warm downloads. The
        // env prefix is prepended to whichever registration script the forge
        // produces; exports are guarded no-ops when the share is absent.
        // The base VM may be macOS or Linux, so the guest picks its own cache root.
        let cachePrefix = RunnerBootstrap.tartCachePrefix(
            mounted: route.cacheMount, selection: cachedToolchainSelection(for: route))
        switch forge.credentials.forge {
        case .github:
            if case .jitConfig = forge.registration {
                let runnerNames = FleetEngine.runnerNames(for: name, count: runnerCount)
                guard runnerNames.allSatisfy({ runnerTokens[$0] != nil }), runnerTokens.count == runnerNames.count else {
                    throw EngineError.registrationFailed(vm: name, stderr: "forge returned incomplete JIT configs")
                }
                let orderedConfigs = runnerNames.compactMap { runnerName in
                    runnerTokens[runnerName].map { (runnerName, $0) }
                }
                let scripts = orderedConfigs.enumerated().map { index, config in
                    // Match the layout `kinhin image prepare` bakes: runner 1 lives in
                    // ~/actions-runner; runners 2..N live in ~/actions-runner-2..N (the
                    // classic script and the image-bake step agree on this). The previous
                    // mapping used ~/actions-runner-(index+1), which produced a missing
                    // ~/actions-runner-1 for the first multi-runner VM.
                    let runnerNumber = index + 1
                    let directory: String
                    let workFolder: String
                    if runnerCount == 1 {
                        directory = "~/actions-runner"
                        workFolder = "_work"
                    } else {
                        directory = runnerNumber == 1
                            ? "~/actions-runner"
                            : "~/actions-runner-\(runnerNumber)"
                        workFolder = runnerNumber == 1
                            ? "_work"
                            : "_work-\(runnerNumber)"
                    }
                    return RunnerBootstrap.jitRegistrationScript(
                        encodedJitConfig: config.1,
                        name: config.0,
                        workFolder: workFolder,
                        agentDirectory: directory,
                        agentTemplate: runnerCount > 1 ? "~/actions-runner" : nil,
                        runnerVersion: RunnerVersionResolver.fallback.github
                    )
                }.joined(separator: "\n")
                return cachePrefix + scripts
            }
            return cachePrefix
                + RunnerBootstrap.registrationScript(
                    configureURL: forge.registrationURL(),
                    token: token,
                    labels: labels ?? forge.labels,
                    ephemeral: route.ephemeral,
                    name: name,
                    runnerCount: runnerCount
                )
        case .gitea, .forgejo:
            // Forgejo shares Gitea's runner binary and registration flow.
            return cachePrefix
                + RunnerBootstrap.linuxGiteaRegistrationScript(
                    instance: forge.registrationURL(),
                    token: token,
                    labels: forge.labels,
                    name: name,
                    runnerCount: runnerCount
                )
        case .gitlab:
            return cachePrefix
                + RunnerBootstrap.gitlabRegistrationScript(
                    instance: forge.registrationURL(),
                    runners: try RunnerBootstrap.gitlabRunners(
                        name: name, runnerCount: runnerCount, tokens: runnerTokens),
                    binary: "\"$HOME/gitlab-runner/gitlab-runner\"",
                    baseDir: "\"$HOME/gitlab-runner\""
                )
        case .buildkite:
            return cachePrefix
                + RunnerBootstrap.buildkiteRegistrationScript(
                    token: token,
                    tags: RunnerBootstrap.buildkiteTags(accountLabels: forge.labels, poolLabels: labels),
                    runnerNames: FleetEngine.runnerNames(for: name, count: runnerCount),
                    ephemeral: route.ephemeral,
                    binary: "\"$HOME/buildkite-agent/buildkite-agent\"",
                    baseDir: "\"$HOME/buildkite-agent\""
                )
        case .azuredevops:
            return cachePrefix
                + RunnerBootstrap.azureRegistrationScript(
                    organization: forge.registrationURL(), token: token, pool: forge.scope,
                    runnerNames: FleetEngine.runnerNames(for: name, count: runnerCount),
                    capabilities: AzureDevOpsForge.capabilityEnvironment(forge.labels),
                    template: "\"$HOME/azure-agent\"", baseDir: "\"$HOME/azure-agents\"", copy: .vmGuest)
        case .bitbucket:
            // A tart base VM may be a macOS or a Linux guest; `auto` lets the
            // guest resolve its own --runtime (Darwin → macos, else linux-shell).
            return cachePrefix
                + RunnerBootstrap.bitbucketRegistrationScript(
                    runners: try RunnerBootstrap.bitbucketRunners(
                        name: name, runnerCount: runnerCount, tokens: runnerTokens),
                    runtime: "auto",
                    runnerCommand: "\"$HOME/bitbucket-runner/runner.sh\"",
                    baseDir: "\"$HOME/bitbucket-runners\"")
        }
    }

    func teardown(id: String) async {
        // Idempotent without a `tart list` round trip: stop then delete, and a
        // VM that is already gone (double deletes from racing lifecycle
        // paths) is success, not a warning.
        await ssh.forgetHostKey(vm: id)
        do {
            try await tart.stop(name: id)
        } catch is CancellationError {
            return
        } catch {
            if Self.vmIsGone(error) { return }
            Log.warn(id, "stopping VM failed: \(error.localizedDescription)")
        }
        do {
            try await tart.delete(name: id)
        } catch is CancellationError {
            return
        } catch {
            if Self.vmIsGone(error) { return }
            Log.warn(id, "deleting VM failed: \(error.localizedDescription)")
        }
    }

    /// Whether a tart failure means the VM does not exist (nothing to tear down).
    static func vmIsGone(_ error: Error) -> Bool {
        guard case TartError.commandFailed(_, let stderr) = error else { return false }
        let text = stderr.lowercased()
        return text.contains("does not exist") || text.contains("not found") || text.contains("no such")
    }
}
