import Foundation
import Synchronization

// MARK: - Engine

/// Every mutable field is either a `Mutex` box (checked `Sendable`) or an
/// immutable collaborator, so the conformance is verified by the compiler
/// rather than asserted.
public final class FleetEngine: Sendable {
    let config: KinhinConfig
    let tart: TartControlling
    let store: FleetStore
    let ssh: SSHExecuting
    let statusBox: FleetStatusBox
    let capacity: Capacity.Plan
    let usageSampler: UsageSampler
    /// Briefly caches pipeline lookups so open pipeline views (polling every
    /// couple of seconds) cost the forge one call per few seconds per VM.
    let pipelineCache = PipelineDetailCache()

    // MARK: - Collaborators (fixed for the engine's lifetime)

    /// Builds the GitHub client for an account's credentials.
    let githubFactory: GitHubClientFactory
    /// Resolves an account's token (forge, account name).
    let tokenLoader: @Sendable (ForgeID, String) throws -> String?
    /// Host snapshot for the pre-spawn disk guard.
    let hostProbe: @Sendable () -> HostResources
    /// How long `detachKeepingInstances()` waits for cancelled lifecycle
    /// tasks before handing the fleet over anyway.
    let lifecycleDrainTimeout: Duration
    let spawnStagger: Duration
    /// How often the ephemeral exit watch polls the instance (default 1s).
    let exitWatchInterval: Duration
    /// Shared runner lists for the exit watchers (see `RunnerDirectory`).
    let runnerDirectory: RunnerDirectory
    /// Timings of the liveness check and the orphan sweep.
    let watchdog: Watchdog
    /// First-seen times of instances with no record (see `sweepOrphans`).
    let orphanState = Mutex(OrphanState())
    /// Wakes a sleeping reconcile loop (`pollSoon()`).
    let pollWake = WakeSignal()

    // MARK: - Mutable state

    /// Attached forges, per-account registration-token caches and the
    /// detached-forge retry schedule.
    let forgeState: Mutex<ForgeState>

    /// Forge instances serving this fleet, keyed by account name.
    public var forges: [String: Forge] { forgeState.withLock { $0.byPlatform } }

    private let _reconcileTask = Mutex<Task<Void, Never>?>(nil)

    var reconcileTask: Task<Void, Never>? {
        get { _reconcileTask.withLock { $0 } }
        set { _reconcileTask.withLock { $0 = newValue } }
    }
    /// One lifecycle task per VM id (removed by the task itself on finish).
    let lifecycleTasks = Mutex<[String: Task<Void, Never>]>([:])
    /// Instances a `deleteVMRecord` is currently tearing down, so the retry
    /// sweep for stuck `.deleting` records never races an in-flight delete.
    let deletesInFlight = Mutex<Set<String>>([])

    /// Whether the fleet is serving and whether it is paused — the single
    /// source of truth (`status()` reads it on every call).
    let runState = Mutex(RunState())
    public var paused: Bool { runState.withLock { $0.paused } }
    var running: Bool { runState.withLock { $0.running } }

    /// The primary runtime: single-pool fleets and the fleet-cap shape
    /// (Apple containers, else Docker slots, else Tart — `Capacity.primaryRuntime`).
    let runtime: any Runtime
    /// Every runtime this fleet can execute on, keyed by id. Lifecycle and
    /// recovery dispatch through this map — no per-runtime branches in the
    /// engine. Fixed per engine (config changes rebuild it via the daemon).
    let runtimesByRuntime: [RuntimeID: any Runtime]
    /// Routing model, caps, named images, project rules and fleet labels as
    /// one atomic snapshot, reloaded live by `applyReloaded(config:)` so a
    /// running fleet picks up route changes without a restart. Take
    /// `router.snapshot` once per decision; the single-field accessors below
    /// are for call sites that need only one part.
    let router: Router
    /// Runtimes whose instances keep failing to register are held back (see `SpawnBackoff`).
    let spawnBackoff = Mutex(SpawnBackoff())
    var routing: RuntimeConfigModel { router.snapshot.model }
    var capsByRuntime: [RuntimeID: Int] { router.snapshot.caps }
    var images: [KinhinConfig.ImageConfig] { router.snapshot.images }
    /// The fleet labels as of the latest reload (`config.labels` is the
    /// construction-time value and goes stale).
    var fleetLabels: [String] { router.snapshot.labels }
    /// Per-project toolchains: the repo-file reader and the builder of derived
    /// per-project images (the `projects:` rules live in `router`).
    let projectSource = ProjectToolchainSource()
    let projectStore: ProjectImageStore
    let projectImages: ProjectImageBuilder
    /// Daily host-cache sweep task (started/stopped with the engine).
    private let _cachePruneTask = Mutex<Task<Void, Never>?>(nil)

    var cachePruneTask: Task<Void, Never>? {
        get { _cachePruneTask.withLock { $0 } }
        set { _cachePruneTask.withLock { $0 = newValue } }
    }

    /// `github` serves every GitHub account unless `dependencies` names a
    /// client factory (tests hand in a fake). `primaryToken` is the primary
    /// GitHub account's token for its construction-time forge.
    public init(
        config: KinhinConfig, github: GitHubServing, tart: TartControlling, store: FleetStore, ssh: SSHExecuting,
        host: HostResources, containerShell: ShellRunning? = nil, dependencies: Dependencies = Dependencies(),
        primaryToken: String = ""
    ) {
        self.githubFactory = dependencies.githubFactory ?? GitHubClientFactory { _ in github }
        self.tokenLoader = dependencies.tokenLoader
        self.hostProbe = dependencies.hostProbe ?? { [host] in host }
        self.lifecycleDrainTimeout = dependencies.lifecycleDrainTimeout
        self.spawnStagger = dependencies.spawnStagger
        self.exitWatchInterval = dependencies.exitWatchInterval
        self.watchdog = dependencies.watchdog
        self.runnerDirectory = RunnerDirectory(ttl: dependencies.runnerCacheTTL ?? dependencies.exitWatchInterval * 5)
        // The primary GitHub account attaches immediately under its account
        // name as an unverified placeholder: demand polling and the reconcile
        // loop work before the fleet starts, while start()'s verified attach
        // (via the account path) is the real gate. Other accounts attach in
        // start()/retry once their tokens load.
        var initial: [String: Forge] = [:]
        if let primary = config.primaryGitHub {
            initial[primary.name] = GitHubForge(
                credentials: .github(
                    token: primaryToken, scope: primary.scope, instance: primary.instance,
                    allowInsecureHTTP: primary.allowInsecureHTTP ?? false),
                labels: config.labels, client: github, account: primary.name)
        }
        self.forgeState = Mutex(ForgeState(byPlatform: initial))
        let shell = containerShell ?? Shell()
        let tartRuntime = TartRuntime(
            tart: tart, bootTimeout: { [config] in config.vmBootTimeout }, tartPath: config.tartPath, ssh: ssh)
        var runtimes: [RuntimeID: any Runtime] = [.tart: tartRuntime]
        if let container = config.container {
            runtimes[.appleContainer] = AppleContainerRuntime(
                shell: shell, image: container.image, cpus: container.cpus, memoryGB: container.memoryGB)
        }
        if let docker = config.docker {
            runtimes[.docker] = DockerRuntime(
                shell: shell, image: docker.image, cpus: docker.cpus, memoryGB: docker.memoryGB,
                platform: docker.platform)
        }
        if config.hostRoutesConfigured {
            runtimes[.host] = HostRuntime(shell: shell)
        }
        self.runtimesByRuntime = runtimes
        self.usageSampler = UsageSampler(
            tart: tart, shell: shell, tartMemoryMB: { [config] in config.vm.memoryGB * 1024 },
            tartCPUCount: { [config] in config.vm.cpuCount })
        self.runtime = runtimes[Capacity.primaryRuntime(of: config)] ?? tartRuntime
        self.config = config
        self.tart = tart
        self.store = store
        self.ssh = ssh
        self.statusBox = FleetStatusBox()
        let projectStore = dependencies.projectImageStore ?? ProjectImageStore()
        self.projectStore = projectStore
        self.projectImages = ProjectImageBuilder(
            tart: tart, store: projectStore, baseImage: config.image, ssh: ssh, bake: dependencies.projectBake)
        // The primary runtime's cap; its disk estimate also feeds the
        // pre-spawn disk guard and `kinhin doctor`.
        self.capacity = Capacity.plan(for: config, host: host)
        self.router = Router(Router.Snapshot.make(config: config, host: host))
    }

    /// Convenience initializer matching the production wiring: GitHub
    /// clients come from `githubFactory` (live by default; injectable in
    /// tests to observe credential swaps).
    public convenience init(
        config: KinhinConfig, pat: String, tart: TartControlling, store: FleetStore, ssh: SSHExecuting,
        host: HostResources, githubFactory: GitHubClientFactory = .live, dependencies: Dependencies = Dependencies()
    ) {
        var resolved = dependencies
        resolved.githubFactory = githubFactory
        // The primary account's instance decides the client's host: nil stays
        // api.github.com, an enterprise account targets its own instance.
        let primary = config.primaryGitHub
        self.init(
            config: config,
            github: githubFactory.make(
                GitHubCredentials(
                    token: pat, scope: config.repo, instance: primary?.instance,
                    allowInsecureHTTP: primary?.allowInsecureHTTP ?? false)),
            tart: tart, store: store, ssh: ssh, host: host,
            dependencies: resolved, primaryToken: pat)
    }
}

// MARK: - Dependencies

extension FleetEngine {
    /// The collaborators an engine is built with, fixed for its lifetime.
    /// The defaults are production's (Keychain tokens); tests inject
    /// hermetic ones.
    public struct Dependencies: Sendable {
        /// Builds each account's GitHub client; nil → the `github` client
        /// handed to the designated initializer serves every account.
        public var githubFactory: GitHubClientFactory?
        /// Resolves an account's token (forge, account name).
        public var tokenLoader: @Sendable (ForgeID, String) throws -> String?
        /// Host snapshot for the pre-spawn disk guard; nil → the
        /// construction-time `host` (hermetic).
        public var hostProbe: (@Sendable () -> HostResources)?
        /// How long a detach waits for cancelled lifecycle tasks.
        public var lifecycleDrainTimeout: Duration
        /// Pause between consecutive instance spawns in one reconcile pass,
        /// so disk I/O does not stampede. Not applied after the last spawn.
        public var spawnStagger: Duration
        /// Interval of the ephemeral runner exit watch (tests shorten it).
        public var exitWatchInterval: Duration
        /// Liveness and orphan-sweep timings (tests shorten them).
        public var watchdog: Watchdog
        /// How long the exit watchers share one runner list per account;
        /// nil → five exit-watch intervals (5 s in production).
        public var runnerCacheTTL: Duration?
        /// Index of derived per-project images; nil → the state directory's.
        var projectImageStore: ProjectImageStore?
        /// Replaces the real image bake (tests); nil → `ImagePreparer`.
        var projectBake: ProjectImageBuilder.Bake?

        public init(
            githubFactory: GitHubClientFactory? = nil,
            tokenLoader: @escaping @Sendable (ForgeID, String) throws -> String? = {
                try KeychainTokenStore.load(forge: $0, name: $1)
            },
            hostProbe: (@Sendable () -> HostResources)? = nil,
            lifecycleDrainTimeout: Duration = .seconds(15),
            spawnStagger: Duration = .milliseconds(1500),
            exitWatchInterval: Duration = .seconds(1),
            watchdog: Watchdog = Watchdog(),
            runnerCacheTTL: Duration? = nil
        ) {
            self.githubFactory = githubFactory
            self.tokenLoader = tokenLoader
            self.hostProbe = hostProbe
            self.lifecycleDrainTimeout = lifecycleDrainTimeout
            self.spawnStagger = spawnStagger
            self.exitWatchInterval = exitWatchInterval
            self.watchdog = watchdog
            self.runnerCacheTTL = runnerCacheTTL
        }

        /// Production: the Keychain and a live disk probe (the GitHub
        /// client factory comes from the convenience initializer).
        public static var live: Dependencies {
            Dependencies(hostProbe: { ResourceProbe().snapshot() })
        }
    }
}
