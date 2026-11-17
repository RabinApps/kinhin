import Foundation

/// kinhin's Docker Hub pull-through cache for `container.docker` runners: one shared Apple container,
/// `registry-cache-kinhin`, running Docker's `registry:3` in proxy mode. Every Docker runner starts with an empty
/// Docker, so without it each job pulls its images (`services:` databases, Docker actions, test images) from Docker
/// Hub again, and every runner on the Mac shares one IP for Docker Hub's anonymous pull limit.
///
/// The first Docker runner that wants the cache starts it; a running container of that name is adopted as it is, and
/// a stopped one is started. Concurrent callers share one start. It is not a runner: its name does not start with
/// `kinhin`, so recovery, the orphan sweep and capacity never count it, and `kinhin image prune` keeps its image while
/// a pool uses it. Apple container gives it a new address on every start (and no DNS name), so each runner asks for
/// the current one (`address()`) when it registers; `AppleContainerRuntime+DockerCache` wires it in.
///
/// Blobs expire after the proxy TTL (`container.registry_cache_ttl_hours`, two weeks by default; 0 keeps them until
/// deleted). An expired blob can leave other repositories' links to it behind, which breaks their pulls, so each runner
/// that asks for the cache first gets the data directory checked and any broken entry deleted
/// (`DockerRegistryCacheStorage`), at most every `storageCheckInterval`.
actor DockerRegistryCache {
    static let containerName = "registry-cache-kinhin"
    static let image = "registry:3"
    /// The port the registry listens on inside its container.
    static let port = 5000
    static let cpus = 1
    static let memory = "1024M"
    /// How long the proxy keeps a blob or manifest before asking Docker Hub again, by default (two weeks).
    static let defaultTTLHours = KinhinConfig.ContainerConfig.defaultRegistryCacheTTLHours
    /// How often a runner's request for the cache also checks its data directory for broken entries.
    static let storageCheckInterval: Duration = .seconds(300)
    static let upstream = "https://registry-1.docker.io"
    /// Where `registry:3` keeps its data inside the container.
    static let guestDataPath = "/var/lib/registry"

    /// The host directory bind-mounted at `guestDataPath`: cached layers survive the container.
    /// `registry_cache_path:` moves it (`StorageLocations`).
    static var defaultDataDirectory: URL {
        StorageLocations.configuredDirectory(.registryCache)
            ?? Paths.appSupport.appendingPathComponent("registry-cache", isDirectory: true)
    }

    /// What `container inspect` says about the cache container.
    struct Inspection: Equatable, Sendable {
        /// The CLI's state ("running", "stopped", ...).
        let state: String
        /// Its IPv4 address on the container network, without the prefix length; nil until it has one.
        let address: String?
        /// The `REGISTRY_PROXY_TTL` it was created with; nil when `container inspect` does not show its environment.
        var ttl: String? = nil
        /// The host directory mounted at `guestDataPath`; nil when `container inspect` does not show its mounts.
        var dataSource: String? = nil

        var isRunning: Bool { state == "running" }
    }

    /// The cache as doctor reports it. Reading it never starts the container.
    struct Status: Equatable, Sendable {
        /// Whether a container of that name exists (running or stopped).
        var exists: Bool
        var running: Bool
        /// The registry's address (`ip:5000`) while it runs.
        var address: String?
        /// Bytes the cached data takes on disk; nil when the directory is missing or unreadable.
        var dataBytes: Int64?
        var dataDirectory: String
        /// Why the container could not be inspected, when it could not.
        var problem: String?
        /// The TTL the running container uses (`REGISTRY_PROXY_TTL`), when it shows it.
        var ttl: String? = nil
        /// The TTL the config asks for; differs from `ttl` until the cache is next started.
        var wantedTTL: String? = nil
        /// What a check of the data directory found; nil when there is no data directory yet.
        var storage: DockerRegistryCacheStorage.Report? = nil
    }

    let shell: ShellRunning
    /// Binary-path override (tests); nil resolves like `AppleContainerRuntime`.
    let binPath: String?
    let dataDirectory: URL
    /// `REGISTRY_PROXY_TTL` in hours (`container.registry_cache_ttl_hours`); 0 never expires anything.
    let ttlHours: Int
    /// How often, and how far apart, a started container is asked for its address before giving up.
    let addressPolls: Int
    let pollInterval: Duration
    /// The start in progress, which concurrent callers join instead of starting a second container.
    private var inFlight: Task<String, any Error>?
    /// Whether the running cache's other data directory was already logged (once per process).
    private var reportedDataMismatch = false
    /// When the data directory was last checked for broken entries (`checkStorageIfDue`).
    private var lastStorageCheck: ContinuousClock.Instant?
    /// Whether a running cache with another TTL than `ttlHours` has been reported (once per engine).
    private var reportedTTLMismatch = false

    init(
        shell: ShellRunning = Shell(), binPath: String? = nil, dataDirectory: URL = defaultDataDirectory,
        ttlHours: Int = defaultTTLHours, addressPolls: Int = 20, pollInterval: Duration = .milliseconds(500)
    ) {
        self.shell = shell
        self.binPath = binPath
        self.dataDirectory = dataDirectory
        self.ttlHours = ttlHours
        self.addressPolls = addressPolls
        self.pollInterval = pollInterval
    }

    var bin: String { binPath ?? AppleContainerRuntime.resolvedBinaryPath }

    /// The `registry-mirrors` entry for the cache at `address`.
    static func mirrorURL(address: String) -> String { "http://\(address):\(port)" }

    /// `REGISTRY_PROXY_TTL` for `hours`: a Go duration, where 0 turns expiry off.
    static func ttlValue(hours: Int) -> String { "\(hours)h" }

    nonisolated var ttl: String { Self.ttlValue(hours: ttlHours) }

    // MARK: - Starting and adopting

    /// The cache's current IPv4 address, starting the container first when it is stopped or missing. Throws when it
    /// cannot be started or read; the caller then pulls from Docker Hub directly.
    func address() async throws -> String {
        try await joined(startOrJoin())
    }

    /// The cache's address when it is running, or once a start finishes within `limit`; nil when the start takes
    /// longer (a first pull of `registry:3`, say). The start goes on in the background, and later callers join or
    /// adopt it, so one slow start never holds a runner's registration for long. Throws like `address()`.
    func address(waitingAtMost limit: Duration) async throws -> String? {
        let start = startOrJoin()
        let first = FirstOutcome<String?>()
        Task {
            do { await first.offer(.success(try await start.value)) } catch { await first.offer(.failure(error)) }
        }
        Task {
            // Nothing cancels this sleep; if something ever did, answering nil early only skips the cache sooner.
            try? await Task.sleep(for: limit)
            await first.offer(.success(nil))
        }
        // A cancelled caller stops waiting at once; the start itself goes on for the other runners.
        let address = try await withTaskCancellationHandler {
            try await first.value()
        } onCancel: {
            Task { await first.offer(.failure(CancellationError())) }
        }
        try Task.checkCancellation()
        return address
    }

    /// The start in progress, or a new one. The start clears itself when it ends, so a caller that stopped waiting
    /// early does not leave a finished start behind for later callers to join.
    private func startOrJoin() -> Task<String, any Error> {
        if let inFlight { return inFlight }
        let task = Task {
            defer { self.inFlight = nil }
            return try await self.runningAddress()
        }
        inFlight = task
        return task
    }

    /// The start's answer, unless the caller was cancelled while it waited (the start itself goes on for the others).
    private func joined(_ task: Task<String, any Error>) async throws -> String {
        let address = try await task.value
        try Task.checkCancellation()
        return address
    }

    private func runningAddress() async throws -> String {
        // A configured data directory on a volume that is away would leave the bind mount empty (or create it on
        // the internal disk): fail here, and the runner pulls from Docker Hub directly.
        if dataDirectory.path == StorageLocations.current.registryCachePath {
            try StoragePreflight.live.requireReady(.registryCache)
        }
        checkStorageIfDue()
        guard let current = try await inspect() else {
            try await create()
            return try await awaitAddress()
        }
        var stale: [String] = []
        if let other = current.ttl, other != ttl {
            if current.isRunning { reportTTLMismatch(running: other) } else { stale.append("TTL \(other) → \(ttl)") }
        }
        if let source = current.dataSource, !StoragePreflight.sameDirectory(source, dataDirectory.path) {
            if current.isRunning {
                reportDataMismatch(running: source)
            } else {
                stale.append("data \(source) → \(dataDirectory.path)")
            }
        }
        if !stale.isEmpty {
            // A stopped cache is recreated with the configured TTL and directory; the old directory keeps its data.
            try await delete(stoppedBecause: stale)
            try await create()
            return try await awaitAddress()
        }
        if current.isRunning, let address = current.address { return address }
        if !current.isRunning { try await start(from: current.state) }
        return try await awaitAddress()
    }

    /// Checks the data directory and deletes broken entries, at most every `storageCheckInterval`. Never throws: a
    /// cache that cannot be checked is used as it is.
    func checkStorageIfDue(now: ContinuousClock.Instant = .now) {
        if let last = lastStorageCheck, now - last < Self.storageCheckInterval { return }
        lastStorageCheck = now
        let report = DockerRegistryCacheStorage.scan(dataDirectory)
        guard !report.isHealthy else { return }
        let removed = DockerRegistryCacheStorage.repair(report, in: dataDirectory)
        let examples = (report.danglingLinks + report.brokenBlobs).prefix(3).joined(separator: ", ")
        Log.warn(
            "container",
            "Docker Hub cache: deleted \(removed) of \(report.problems) broken entries (links to blobs the proxy "
                + "TTL expired, or empty blobs), so their next pull fetches them from Docker Hub again: \(examples)")
    }

    private func reportTTLMismatch(running other: String) {
        guard !reportedTTLMismatch else { return }
        reportedTTLMismatch = true
        Log.warn(
            "container",
            "the Docker Hub cache runs with TTL \(other), the config asks for \(ttl); it changes the next time the "
                + "cache starts (container stop \(Self.containerName) applies it once no job is pulling)")
    }

    /// A running cache keeps its directory until it stops: recreating it would break the pulls of every runner using
    /// it. Logged once.
    private func reportDataMismatch(running source: String) {
        guard !reportedDataMismatch else { return }
        reportedDataMismatch = true
        Log.warn(
            "container",
            "the Docker Hub cache keeps its data in \(source), the config asks for \(dataDirectory.path); it moves "
                + "the next time the cache starts (container stop \(Self.containerName) applies it once no job is "
                + "pulling)")
    }

    /// Deletes the stopped cache container so it can be created again with the configured TTL and data directory.
    private func delete(stoppedBecause reasons: [String]) async throws {
        Log.info(
            "container",
            "recreating the stopped Docker Hub cache \(Self.containerName): \(reasons.joined(separator: ", "))")
        let result = try await shell.run([bin, "delete", Self.containerName], cwd: nil, timeout: 60)
        guard result.succeeded || result.stderr.localizedCaseInsensitiveContains("not found") else {
            throw ContainerManagerError.commandFailed(
                what: "container: deleting \(Self.containerName)", stderr: result.failureExcerpt)
        }
    }

    private func start(from state: String) async throws {
        Log.info("container", "starting the \(state) Docker Hub cache \(Self.containerName)")
        let result = try await shell.run([bin, "start", Self.containerName], cwd: nil, timeout: 120)
        guard result.succeeded else {
            throw ContainerManagerError.commandFailed(
                what: "container: starting \(Self.containerName)", stderr: result.failureExcerpt)
        }
    }

    private func create() async throws {
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        } catch {
            throw ContainerManagerError.registryCache(
                "could not create \(dataDirectory.path): \(error.localizedDescription)")
        }
        Log.info(
            "container",
            "starting the Docker Hub cache \(Self.containerName) (\(Self.image), data in \(dataDirectory.path))")
        // The first start pulls registry:3, so allow for a slow network.
        let result = try await shell.run(
            Self.runArguments(bin: bin, dataDirectory: dataDirectory, ttlHours: ttlHours), cwd: nil, timeout: 600)
        guard result.succeeded else {
            // Created by someone else between the inspect and the run (another kinhin, a person): adopt it.
            if let raced = try await inspect() {
                if !raced.isRunning { try await start(from: raced.state) }
                return
            }
            throw ContainerManagerError.commandFailed(
                what: "container: starting \(Self.containerName) from \(Self.image)", stderr: result.failureExcerpt)
        }
    }

    /// The `container run` argv that creates the cache. No `--rm`: a cache stopped with the host keeps its container,
    /// and the next runner starts it again.
    static func runArguments(bin: String, dataDirectory: URL, ttlHours: Int = defaultTTLHours) -> [String] {
        [
            bin, "run", "--detach", "--name", containerName, "--cpus", String(cpus), "--memory", memory,
            "--volume", "\(dataDirectory.path):\(guestDataPath)",
            "--env", "REGISTRY_PROXY_REMOTEURL=\(upstream)",
            "--env", "REGISTRY_PROXY_TTL=\(ttlValue(hours: ttlHours))",
            image,
        ]
    }

    /// Polls until the started container runs with an address: Apple container assigns it shortly after the start.
    private func awaitAddress() async throws -> String {
        var last: Inspection?
        for attempt in 0..<max(1, addressPolls) {
            if attempt > 0 { try await Task.sleep(for: pollInterval) }
            last = try await inspect()
            if let last, last.isRunning, let address = last.address { return address }
        }
        guard let last else { throw ContainerManagerError.registryCache("the container disappeared after it started") }
        throw ContainerManagerError.registryCache(
            last.isRunning ? "it has no IPv4 address" : "it is \(last.state), not running")
    }

    // MARK: - Reading

    /// The cache container, or nil when there is none.
    func inspect() async throws -> Inspection? {
        let result = try await shell.run([bin, "inspect", Self.containerName], cwd: nil, timeout: 30)
        guard result.succeeded else {
            if result.stderr.localizedCaseInsensitiveContains("not found") { return nil }
            throw ContainerManagerError.commandFailed(
                what: "container: inspecting \(Self.containerName)", stderr: result.failureExcerpt)
        }
        return try Self.parseInspection(result.stdout)
    }

    /// `container inspect NAME` (a JSON array): the first entry's `status.state`, the IPv4 address of its first
    /// network, without the prefix length, and the `REGISTRY_PROXY_TTL` in its init process's environment
    /// (`configuration.initProcess.environment`, when shown). nil for an empty array (no such container); throws for
    /// anything else that is not that shape.
    static func parseInspection(_ text: String) throws -> Inspection? {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
        } catch {
            throw ContainerManagerError.registryCache("`container inspect` printed something that is not JSON")
        }
        guard let entries = parsed as? [[String: Any]] else {
            throw ContainerManagerError.registryCache("`container inspect` printed an unexpected shape")
        }
        guard let first = entries.first else { return nil }
        guard let status = first["status"] as? [String: Any], let state = status["state"] as? String else {
            throw ContainerManagerError.registryCache("`container inspect` printed no state")
        }
        let networks = status["networks"] as? [[String: Any]] ?? []
        let address = networks.lazy.compactMap { $0["ipv4Address"] as? String }.first
            .map { String($0.split(separator: "/").first ?? Substring($0)) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let configuration = first["configuration"] as? [String: Any]
        let initProcess = configuration?["initProcess"] as? [String: Any]
        let environment = initProcess?["environment"] as? [String] ?? []
        let ttlPrefix = "REGISTRY_PROXY_TTL="
        let ttl = environment.first { $0.hasPrefix(ttlPrefix) }.map { String($0.dropFirst(ttlPrefix.count)) }
        let mounts = configuration?["mounts"] as? [[String: Any]] ?? []
        let source = mounts.first { $0["destination"] as? String == guestDataPath }?["source"] as? String
        return Inspection(state: state, address: address, ttl: ttl, dataSource: source)
    }

    /// The cache's state for doctor, read without starting anything.
    func status() async -> Status {
        let bytes = Self.dataBytes(at: dataDirectory)
        var status = Status(
            exists: false, running: false, address: nil, dataBytes: bytes, dataDirectory: dataDirectory.path,
            wantedTTL: ttl, storage: bytes == nil ? nil : DockerRegistryCacheStorage.scan(dataDirectory))
        do {
            guard let current = try await inspect() else { return status }
            status.exists = true
            status.running = current.isRunning
            status.ttl = current.ttl
            if current.isRunning, let address = current.address { status.address = "\(address):\(Self.port)" }
        } catch {
            status.problem = error.localizedDescription
        }
        return status
    }

    /// The bytes the files under `directory` take on disk; nil when it is missing or cannot be read.
    static func dataBytes(at directory: URL) -> Int64? {
        // The directory may be a symlink (to an external disk, say): the enumerator would not follow it.
        let directory = DockerRegistryCacheStorage.canonical(directory)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard FileManager.default.fileExists(atPath: directory.path),
            let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys)
        else { return nil }
        var total: Int64 = 0
        for case let url as URL in walk {
            // A file that vanished or cannot be read mid-walk is left out: the size is an estimate for doctor.
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// The first of several racing outcomes; later offers are ignored.
private actor FirstOutcome<Value: Sendable> {
    private var outcome: Result<Value, any Error>?
    private var waiters: [CheckedContinuation<Value, any Error>] = []

    func offer(_ result: Result<Value, any Error>) {
        guard outcome == nil else { return }
        outcome = result
        waiters.forEach { $0.resume(with: result) }
        waiters = []
    }

    func value() async throws -> Value {
        if let outcome { return try outcome.get() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
}
