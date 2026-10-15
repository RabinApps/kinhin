import Foundation

/// Names of benchmark instances. The prefix keeps them inside `kinhin-*`
/// (so `kinhin cleanup` finds strays) yet out of the engine's own adoption
/// and orphan paths, which only claim generated runner names.
enum BenchmarkNaming {
    static let instancePrefix = InstanceNaming.prefix + "bench-"
    static func instanceName(runShort: String, index: Int) -> String {
        "\(instancePrefix)\(runShort)-\(index)"
    }
}

/// Everything a run reaches the machine through, injected so tests drive the
/// runner over fakes. Holds no credentials: a benchmark never reads the
/// Keychain or registers with a forge.
public struct BenchmarkEnvironment: Sendable {
    public var config: KinhinConfig
    public var tart: TartControlling
    public var ssh: SSHExecuting
    public var shell: ShellRunning
    /// Builds the runtime for an id; `platform` selects Docker's architecture. nil = unsupported here.
    var makeRuntime: @Sendable (RuntimeID, LinuxPlatform?) -> (any Runtime)?
    /// Prerequisite probe for a runtime.
    var health: @Sendable (RuntimeID, any Runtime) async -> RuntimeHealth
    /// Image names present locally for a runtime.
    var localImages: @Sendable (RuntimeID) async throws -> [String]
    /// The CPU architecture of a local Docker image, nil when unknown.
    var dockerImageArchitecture: @Sendable (String) async -> String?
    var hostResources: @Sendable () -> HostResources
    var hostInfo: @Sendable () -> (chip: String, os: String)
    /// Builds the runner the video suite times, handing each line of a build's output to the callback (the suite keeps
    /// the tail for a failure message). Builds go to the container runtimes through `shell`.
    var videoRunner: @Sendable (@escaping @Sendable (String) -> Void) -> VideoRunner
    /// The bench directory: history and per-run scratch.
    public var root: URL
    /// Nil = no fleet to pause (a CLI run with no daemon).
    public var fleet: BenchmarkFleetControlling?
    /// Pause between SSH-port probes while timing boot.
    var probeInterval: Duration
    /// How often a pause waits on busy VMs, and for how long before giving up.
    var drainPoll: Duration = .seconds(2)
    /// Guard scripts against children that read stdin (see `BenchmarkScripts.isolatingStdin`). Tests that
    /// inspect the raw script turn it off.
    var isolatesStdin = true
    var drainSeconds: TimeInterval = BenchmarkLimits.drainSeconds

    public init(
        config: KinhinConfig, tart: TartControlling, ssh: SSHExecuting, shell: ShellRunning = Shell(),
        root: URL = BenchmarkReportStore.defaultDirectory, fleet: BenchmarkFleetControlling? = nil
    ) {
        self.config = config
        self.tart = tart
        self.ssh = ssh
        self.shell = shell
        self.root = root
        self.fleet = fleet
        self.probeInterval = .milliseconds(250)
        self.hostResources = { ResourceProbe().snapshot() }
        self.hostInfo = { (Self.chipName(), ProcessInfo.processInfo.operatingSystemVersionString) }
        self.makeRuntime = { _, _ in nil }
        self.videoRunner = { onLine in VideoRunner(shell: shell, process: CapturingProcessRunner(onLine: onLine)) }
        self.health = { _, runtime in await runtime.health() }
        self.localImages = { _ in [] }
        self.dockerImageArchitecture = { _ in nil }
        installProductionRuntimes()
    }

    /// The production wiring over the real tart, ssh and CLIs for `config`.
    public static func production(
        config: KinhinConfig, fleet: BenchmarkFleetControlling? = nil, root: URL = BenchmarkReportStore.defaultDirectory
    ) throws -> BenchmarkEnvironment {
        BenchmarkEnvironment(
            config: config, tart: try config.makeTartControlling(), ssh: SSHExecutor(), shell: Shell(), root: root,
            fleet: fleet)
    }

    /// Runtimes built from `config` over this environment's tart, ssh and shell.
    mutating func installProductionRuntimes() {
        let config = self.config
        let tart = self.tart
        let ssh = self.ssh
        let shell = self.shell
        makeRuntime = { id, platform in
            switch id {
            case .tart:
                return TartRuntime(
                    tart: tart, bootTimeout: { config.vmBootTimeout }, tartPath: config.tartPath, ssh: ssh)
            case .appleContainer:
                return AppleContainerRuntime(
                    shell: shell, image: config.container?.image ?? Self.defaultLinuxImage,
                    cpus: config.container?.cpus ?? KinhinConfig.ContainerConfig.defaultCPUs,
                    memoryGB: config.container?.memoryGB ?? KinhinConfig.ContainerConfig.defaultMemoryGB)
            case .docker:
                return DockerRuntime(
                    shell: shell, image: config.docker?.image ?? Self.defaultLinuxImage,
                    cpus: config.docker?.cpus ?? KinhinConfig.DockerForgeConfig.defaultCPUs,
                    memoryGB: config.docker?.memoryGB ?? KinhinConfig.DockerForgeConfig.defaultMemoryGB,
                    platform: platform ?? config.docker?.platform ?? .arm64)
            case .host:
                return HostRuntime(shell: shell)
            }
        }
        localImages = { id in
            switch id {
            case .tart: return try await tart.list().map(\.name)
            case .appleContainer:
                return await AppleContainerRuntime(shell: shell, image: Self.defaultLinuxImage).localImageNames()
            case .docker:
                return await DockerRuntime(shell: shell, image: Self.defaultLinuxImage).localImageNames()
            case .host: return []
            }
        }
        dockerImageArchitecture = { image in
            await DockerRuntime(shell: shell, image: image).imageArchitecture(of: image)
        }
    }

    static let defaultLinuxImage = "kinhin-ci-linux"

    /// The image a runtime boots from under this config.
    func image(for runtime: RuntimeID) -> String {
        switch runtime {
        case .tart: return config.image
        case .appleContainer: return config.container?.image ?? Self.defaultLinuxImage
        case .docker: return config.docker?.image ?? Self.defaultLinuxImage
        case .host: return "host"
        }
    }

    static func chipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [UInt8](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
