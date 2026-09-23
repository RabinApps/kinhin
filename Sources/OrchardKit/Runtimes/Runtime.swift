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
    public let bootTimeout: Int

    public init(repo: String, image: String, ephemeral: Bool, bootTimeout: Int) {
        self.repo = repo
        self.image = image
        self.ephemeral = ephemeral
        self.bootTimeout = bootTimeout
    }

    /// The route implied by today's single-fleet config.
    public static func from(config: OrchardConfig) -> RepoRoute {
        RepoRoute(
            repo: config.repo,
            image: config.image,
            ephemeral: config.vm.ephemeral,
            bootTimeout: config.vmBootTimeout
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

    /// The bootstrap script that turns the provisioned instance into N
    /// registered runners (GitHub/Gitea scripts today). The engine executes
    /// it inside the instance. `labels` overrides the forge's default label
    /// set for the GitHub branch — the pool's labels in mixed fleets.
    func registrationScript(forge: Forge, token: String, name: String,
                            runnerCount: Int, route: RepoRoute, labels: [String]?) async throws -> String

    /// Watch the instance's runners until the ephemeral exit condition holds
    /// (all runners gone, or idle grace for runtimes without deregistration).
    /// Returns normally when the instance is ready to be torn down.
    func watchExit(id: String, forge: Forge, runnerCount: Int, route: RepoRoute) async throws

    /// Stop and remove the instance. Must be idempotent.
    func teardown(id: String) async
}

// MARK: - Tart implementation

/// The original runtime: Tart macOS VMs. Wraps the exact calls the engine
/// made directly before the refactor — behavior-preserving by construction.
public struct TartRuntime: Runtime {
    public let id: RuntimeID = .tart
    let tart: TartControlling
    let bootTimeout: @Sendable () -> Int

    public init(tart: TartControlling, bootTimeout: @escaping @Sendable () -> Int) {
        self.tart = tart
        self.bootTimeout = bootTimeout
    }

    public func health() async -> RuntimeHealth {
        let probe = TartHealthProbe()
        let health = await probe.check()
        switch health {
        case .healthy:
            return .ready
        case .missing:
            return .missing(tool: "tart", fix: "brew tap openai/tools && brew trust openai/tools && brew install openai/tools/tart")
        case .killedOnLaunch:
            return .missing(tool: "tart (notarization rollback)", fix: "roll back to the notarized Cirrus Labs build")
        case .broken(let why):
            return .broken(why)
        }
    }

    public func provision(id: String, route: RepoRoute) async throws {
        let existing = (try? await tart.list()) ?? []
        if existing.contains(where: { $0.name == id }) {
            Log.info(id, "VM already exists; reusing (recovery)")
            return
        }
        Log.info(id, "cloning from \(route.image)")
        try await tart.clone(source: route.image, to: id)
        try await tart.run(name: id)
    }

    public func registrationScript(forge: Forge, token: String, name: String,
                                   runnerCount: Int, route: RepoRoute, labels: [String]?) async throws -> String {
        switch forge.credentials {
        case .github:
            return RunnerBootstrap.registrationScript(
                configureURL: forge.registrationURL(),
                token: token,
                labels: labels ?? forge.labels,
                ephemeral: route.ephemeral,
                name: name,
                runnerCount: runnerCount
            )
        case .gitea:
            return RunnerBootstrap.giteaRegistrationScript(
                instance: forge.registrationURL(),
                token: token,
                labels: forge.labels,
                name: name,
                runnerCount: runnerCount
            )
        }
    }

    /// The engine's watches are forge-specific today (GitHub deregistration
    /// semantics vs Gitea idle-grace); the runtime exposes them as the
    /// exit-wait, selected by forge id. Stage 1 keeps the engine's existing
    /// watch methods authoritative — this hook exists for symmetry and for
    /// non-VM runtimes to override later.
    public func watchExit(id: String, forge: Forge, runnerCount: Int, route: RepoRoute) async throws {
        // Engine-owned watch (needs the record store + statusBox); nothing to
        // do at the runtime layer for Tart. Non-VM runtimes implement their
        // own container/host polling here in stages 3–4.
    }

    public func teardown(id: String) async {
        // Existence check makes teardown genuinely idempotent (double deletes
        // from racing lifecycle paths must not error or double-charge).
        let existing = (try? await tart.list()) ?? []
        guard existing.contains(where: { $0.name == id }) else { return }
        try? await tart.stop(name: id)
        try? await tart.delete(name: id)
    }
}
