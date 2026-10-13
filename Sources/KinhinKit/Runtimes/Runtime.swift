import Foundation

// MARK: - Runtime identity

/// Where runner workloads execute: Tart macOS/Linux VMs, Apple's `container`
/// CLI, Docker, or the host itself.
public enum RuntimeID: String, Codable, Sendable, CaseIterable {
    case tart
    /// Apple's `container` CLI (github.com/apple/container): Linux runner
    /// workloads in per-container microVMs on Apple silicon. An alternative
    /// to the Docker runtime for Linux jobs — no daemon, no shared VM.
    case appleContainer
    case docker
    case host
}

/// Whether a provisioned instance is still alive, as its runtime sees it.
public enum InstanceState: Sendable, Equatable {
    /// Up and executing.
    case running
    /// Exists but is not executing (a halted VM or container).
    case stopped
    /// No longer exists (deleted out of band, or a `--rm` container that exited).
    case gone
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
/// for one repo: the fleet's config values, or the per-project image a record
/// was bound to.
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

    /// Whether the instance is running, stopped or gone. Throws when the
    /// runtime can't be asked: a failed query must never read as "gone". The
    /// default answers from `existingInstanceIDs()` (present = running), which
    /// is the best a runtime without a finer signal can say.
    func state(id: String) async throws -> InstanceState

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

    /// Stop and remove the instance. Must be idempotent: an instance that is
    /// already gone is success. Throws when it could not be removed, so the
    /// engine keeps the record (and retries) instead of leaking the instance.
    func teardown(id: String) async throws
}

extension Runtime {
    func state(id: String) async throws -> InstanceState {
        try await existingInstanceIDs().contains(id) ? .running : .gone
    }

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
    /// The configured tart binary (`tart_path:`; nil = search PATH). The
    /// health probe must ask the same binary the runtime runs through
    /// `tart` — a configured-but-broken path reads as missing even when
    /// another tart sits on PATH, and an unconfigured one reads PATH.
    let tartPath: String?
    /// Runs the health probe's `tart --version`. Injectable so tests can
    /// answer without launching a real binary or reading the unified log.
    let healthShell: ShellRunning
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
        tart: TartControlling, bootTimeout: @escaping @Sendable () -> Int, tartPath: String? = nil,
        healthShell: ShellRunning = Shell(),
        ssh: SSHExecuting = SSHExecutor(), sshReadyWindow: TimeInterval = 120,
        sshRetryInterval: Duration = .seconds(1), sshProbeInterval: Duration = .milliseconds(500),
        hostKeyWindow: TimeInterval = 30, hostKeyInterval: Duration = .seconds(2)
    ) {
        self.tart = tart
        self.bootTimeout = bootTimeout
        self.tartPath = tartPath
        self.healthShell = healthShell
        self.ssh = ssh
        self.sshReadyWindow = sshReadyWindow
        self.sshRetryInterval = sshRetryInterval
        self.sshProbeInterval = sshProbeInterval
        self.hostKeyWindow = hostKeyWindow
        self.hostKeyInterval = hostKeyInterval
    }

    func health() async -> RuntimeHealth {
        let probe = TartHealthProbe(shell: healthShell, configuredPath: tartPath)
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

    func state(id: String) async throws -> InstanceState {
        guard let vm = try await tart.list().first(where: { $0.name == id }) else { return .gone }
        return vm.status.lowercased() == "running" ? .running : .stopped
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
        let request = RegistrationRequest(
            forge: forge, token: token, runnerTokens: runnerTokens, name: name, runnerCount: runnerCount,
            route: route, labels: labels)
        // The agents the script starts pass its PATH on to every job; see `guestLoginPathPrelude`.
        return RunnerBootstrap.guestLoginPathPrelude + "\n" + cachePrefix
            + (try forge.credentials.forge.descriptor.registrationScript(for: .tartVM, request))
    }

    func teardown(id: String) async throws {
        // Idempotent without a `tart list` round trip: stop then delete, and a
        // VM that is already gone (double deletes from racing lifecycle
        // paths) is success, not a warning. A failed stop is only logged (the
        // delete below usually still works); a failed delete throws so the
        // caller keeps the record instead of losing track of the disk.
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
            throw error
        }
    }

    /// Whether a tart failure means the VM does not exist (nothing to tear down).
    static func vmIsGone(_ error: Error) -> Bool {
        guard case TartError.commandFailed(_, let stderr) = error else { return false }
        let text = stderr.lowercased()
        return text.contains("does not exist") || text.contains("not found") || text.contains("no such")
    }
}
