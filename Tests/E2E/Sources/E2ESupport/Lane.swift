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
        public init() {}
    }

    /// Stands up the forge, bakes the image, writes the config and (by default) starts the daemon.
    public static func start(forge: ForgeKind, runtime: RuntimeKind, options: Options = Options()) async throws
        -> Lane
    {
        guard runtime.isAvailable else { throw E2EError.unavailable(runtime.unavailableReason) }
        let fixture: any ForgeFixture
        switch forge {
        case .gitea, .forgejo: fixture = try GiteaFixture(kind: forge)
        case .gitlab: fixture = try GitLabFixture()
        case .github: fixture = try GitHubFixture()
        }
        try await fixture.start()
        do {
            let account = await fixture.account
            let image = try await ImageBaker.shared.ensure(runtime, accounts: [account])
            let sandbox = try Sandbox()
            sandbox.setToken(await fixture.token, account: account.name)
            var config = FleetConfig(accounts: [account], runtime: runtime, image: image)
            config.minRunners = options.minRunners ?? (fixture.needsRunnerFloor ? 1 : 0)
            config.maxRunners = options.maxRunners
            config.extra = options.extraConfig
            try sandbox.writeConfig(config.yaml())
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
            name: name, runsOn: runtime.runsOn, nonce: nonce, script: fixture.proofScript(extra: extraStep))
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
