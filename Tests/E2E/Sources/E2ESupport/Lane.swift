import Foundation

/// A complete, running scenario environment: a real forge, a sandboxed kinhin install, a baked image and a live
/// daemon, wired together. Build one with `Lane.start`, and always `await lane.tearDown()` (use `defer` in a `Task`
/// or `do/catch`), which removes everything the lane created.
public final class Lane: @unchecked Sendable {
    public let fixture: any ForgeFixture
    public let sandbox: Sandbox
    public let runtime: RuntimeKind
    public let image: String
    public private(set) var daemon: Daemon?
    private var tornDown = false

    init(fixture: any ForgeFixture, sandbox: Sandbox, runtime: RuntimeKind, image: String) {
        self.fixture = fixture
        self.sandbox = sandbox
        self.runtime = runtime
        self.image = image
    }

    public struct Options: Sendable {
        /// `nil` picks what the forge needs: 1 when it only shows work to a registered runner, else 0.
        public var minRunners: Int?
        public var maxRunners = 1
        public var extraConfig = ""
        /// Skip starting the daemon (the scenario starts it itself).
        public var startDaemon = true
        /// A Gitea/Forgejo image instead of the pinned (or `KINHIN_E2E_*_IMAGE`) one.
        public var forgeImage: String?
        /// Extra variables for every kinhin the lane runs (see `Sandbox.setEnvironment`).
        public var environment: [String: String] = [:]
        public init() {}
    }

    /// Stands up the forge, bakes the image, writes the config and (by default) starts the daemon.
    public static func start(forge: ForgeKind, runtime: RuntimeKind, options: Options = Options()) async throws
        -> Lane
    {
        guard runtime.isAvailable else { throw E2EError.unavailable(runtime.unavailableReason) }
        // kinhin adopts every instance its runtime lists that carries its prefix. This suite's daemon uses `ke2e-`, so a
        // real fleet's `kinhin-*` instances are never adopted. Leftovers of an earlier run are, and Tart's VM cap is
        // per Mac, so a Tart lane also refuses to run beside a real fleet's VMs.
        let foreign = await Instances.foreign(for: runtime)
        guard foreign.isEmpty else {
            throw E2EError.failed(
                "refusing to start a \(runtime) lane next to instances it does not own: \(foreign). Remove the "
                    + "leftovers (scripts/e2e-sweep.sh), or stop the fleet's Tart VMs before a Tart lane.")
        }
        let fixture: any ForgeFixture
        switch forge {
        // Host lanes run with no floor, so they need a Gitea that lists queued jobs before a runner exists.
        case .gitea where options.forgeImage == nil && runtime == .host && E2E.flag("KINHIN_E2E_GITEA_IMAGE") == nil:
            fixture = try GiteaFixture(kind: forge, image: GiteaFixture.floorFreeGiteaImage)
        case .gitea, .forgejo: fixture = try GiteaFixture(kind: forge, image: options.forgeImage)
        case .gitlab: fixture = try GitLabFixture()
        case .github: fixture = try GitHubFixture()
        }
        let minRunners = options.minRunners ?? (fixture.needsRunnerFloor ? 1 : 0)
        if runtime == .host, minRunners > 0 {
            throw E2EError.unavailable("a min_runners floor lands in the default pool, not the host route")
        }
        try await fixture.start()
        do {
            let account = await fixture.account
            let sandbox = try Sandbox()
            let image: String
            if runtime == .host {
                // Nothing to bake: the "image" of a host lane is its sandbox, where the agents and work dirs live.
                image = sandbox.supportDirectory.path
            } else {
                image = try await ImageBaker.shared.ensure(runtime, accounts: [account])
            }
            sandbox.setToken(await fixture.token, account: account.name)
            for (key, value) in options.environment { sandbox.setEnvironment(key, value) }
            var config = FleetConfig(accounts: [account], runtime: runtime, image: image)
            config.minRunners = minRunners
            config.maxRunners = options.maxRunners
            config.extra = options.extraConfig
            try sandbox.writeConfig(config.yaml())
            if runtime == .host {
                let installed = try await sandbox.kinhin(["setup", "repair", "host-agent"], timeout: 900)
                guard installed.ok else {
                    throw E2EError.failed("host agent install failed (\(installed.status)): \(installed.output)")
                }
            }
            let lane = Lane(fixture: fixture, sandbox: sandbox, runtime: runtime, image: image)
            if options.startDaemon { try await lane.startDaemon() }
            return lane
        } catch {
            await fixture.stop()
            throw error
        }
    }

    /// Runs `body` in a fresh lane and always tears it down. A failure carries the tail of kinhin's own log.
    public static func with<T>(
        forge: ForgeKind, runtime: RuntimeKind, options: Options = Options(), _ body: (Lane) async throws -> T
    ) async throws -> T {
        let lane = try await start(forge: forge, runtime: runtime, options: options)
        do {
            let value = try await body(lane)
            await lane.tearDown()
            return value
        } catch {
            let tail = lane.logTail()
            await lane.tearDown()
            throw E2EError.failed("\(error)\n--- kinhin log (tail) ---\n\(tail)")
        }
    }

    public func startDaemon() async throws {
        daemon = try await sandbox.startDaemon()
    }

    /// Runs a script as a job and returns the proof the job wrote to the forge.
    public func runJob(
        name: String = "e2e", extraStep: String = "", timeout: TimeInterval = 480
    ) async throws -> (nonce: String, proof: String) {
        let nonce = E2E.randomID() + E2E.randomID()
        try await fixture.pushWorkflow(
            name: name, runtime: runtime, nonce: nonce, script: fixture.proofScript(extra: extraStep))
        let proof = try await fixture.awaitProof(nonce: nonce, timeout: timeout)
        return (nonce, proof)
    }

    /// Stops everything the lane started. Idempotent, and safe after a failed scenario.
    public func tearDown() async {
        guard !tornDown else { return }
        tornDown = true
        await daemon?.stop()
        await Instances.removeAll(runtime, image: image)
        await fixture.stop()
        // KINHIN_E2E_KEEP=1 leaves the sandbox (config, logs) behind for debugging a failed run.
        if E2E.flag("KINHIN_E2E_KEEP") == nil { sandbox.dispose() }
    }

    /// The last lines of kinhin's own log, for failure messages.
    public func logTail(_ lines: Int = 40) -> String {
        sandbox.log().split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}
