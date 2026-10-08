import Foundation

/// Execution runtime backed by Docker: Linux runner containers inside the
/// provider's shared Linux VM (Docker Desktop, OrbStack, or colima). kinhin
/// delegates the VM — it never starts, stops, or configures the provider —
/// and runs one container per job slot (`--cpus`/`--memory` per slot),
/// exactly the slot model the capacity partition counts. Registration reuses
/// the same Linux agent scripts as the Apple-container runtime, executed via
/// `docker exec` (no SSH, no guest IP).
///
/// The toolchain cache mount (`RepoRoute.cacheMount`) bind-mounts the same
/// host cache the VMs and Apple containers use (`docker run -v host:guest`,
/// guest path `/var/kinhin-cache`), and registration scripts get the guarded
/// Linux cache-env exports — so `npm ci`, `go mod download`, `dotnet restore`,
/// and friends hit warm downloads on every provider.
public struct DockerRuntime: Runtime {
    public let id: RuntimeID = .docker

    /// The `docker` CLI runner (injectable for tests).
    let shell: ShellRunning
    /// Linux OCI image baked with the runner agents (`kinhin image prepare --docker`).
    let image: String
    /// vCPUs per runner container.
    let cpus: Int
    /// Memory per runner container (bytes).
    let memoryBytes: Int64
    /// Container architecture (`--platform`). arm64 is native; amd64 is emulated.
    let platform: LinuxPlatform
    /// Binary-path override (tests); nil resolves from PATH/well-known paths.
    let binPath: String?
    /// Existence probe for the binary (tests inject a constant; production
    /// checks the filesystem).
    let exists: @Sendable (String) -> Bool

    public init(
        shell: ShellRunning = Shell(),
        image: String,
        cpus: Int = 2,
        memoryGB: Int = 4,
        platform: LinuxPlatform = .arm64,
        binPath: String? = nil,
        exists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.shell = shell
        self.image = image
        self.cpus = cpus
        self.memoryBytes = Int64(memoryGB) * 1_073_741_824
        self.platform = platform
        self.binPath = binPath
        self.exists = exists
    }

    /// Resolved path of the `docker` CLI. Public so the CLI doctor and the
    /// checklist invoke the same binary the runtime uses.
    public static var resolvedBinaryPath: String {
        if let found = Paths.findExecutable(named: "docker") { return found }
        let candidates = [
            NSHomeDirectory() + "/.docker/bin/docker",  // Docker Desktop's CLI path
            "/usr/local/bin/docker",  // Docker Desktop symlink / colima
            "/opt/homebrew/bin/docker",  // brew-installed CLI
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/usr/local/bin/docker"
    }

    var bin: String { binPath ?? Self.resolvedBinaryPath }

    /// The shared container-CLI driver in Docker's dialect.
    var cli: LinuxContainerCLI {
        LinuxContainerCLI(
            shell: shell, bin: bin,
            dialect: .init(
                tag: "docker", listVerb: "ps", removeVerb: "rm",
                listNameArguments: ["--format", "{{.Names}}"],
                imageListArguments: ["images", "--format", "{{.Repository}}:{{.Tag}}"],
                imageRemoveArguments: ["image", "rm"],
                // The pids limit stops a fork bomb in one job from starving the host. Capabilities
                // and no-new-privileges stay at Docker's defaults: jobs apt-get and sudo.
                runFlags: ["--platform", platform.rawValue, "--pids-limit", "4096"], shapeNote: platform.rawValue),
            image: image, cpus: cpus, memoryBytes: memoryBytes)
    }

    // MARK: - Health

    public func health() async -> RuntimeHealth {
        let resolved = binPath ?? Self.resolvedBinaryPath
        guard exists(resolved) else {
            return .missing(
                tool: "docker",
                fix: "install Docker Desktop (or colima: brew install colima && colima start)"
            )
        }
        // The CLI exists; require the daemon to answer (every command fails
        // opaquely otherwise). One probe covers all three providers.
        do {
            let info = try await run([resolved, "info", "--format", "{{.ServerVersion}}"])
            if info.succeeded, !info.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .ready
            }
        } catch {
            Log.warn("docker", "daemon probe failed: \(error.localizedDescription)")
        }
        return .broken("the Docker daemon is not reachable — start Docker Desktop (or: colima start)")
    }

    // MARK: - Lifecycle (the shared container CLI)

    public func provision(id: String, route: RepoRoute) async throws {
        try await cli.provision(id: id, route: route)
    }

    /// The bootstrap script (same forge scripts the Apple-container runtime
    /// uses — Linux agent paths), run inside the container via `exec`.
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

    public func teardown(id: String) async throws {
        try await cli.teardown(id: id)
    }

    /// All container ids known to the CLI (running + stopped) — the
    /// recovery path's instance enumeration.
    public func existingInstanceIDs() async throws -> [String] {
        try await cli.containerIDs(all: true)
    }

    public func state(id: String) async throws -> InstanceState {
        try await cli.state(id: id)
    }

    /// The CPU architecture of a local image (`arm64`/`amd64`), nil when the
    /// image is absent or the CLI can't say.
    public func imageArchitecture(of reference: String) async -> String? {
        do {
            let result = try await run([bin, "image", "inspect", "--format", "{{.Architecture}}", reference])
            guard result.succeeded else { return nil }
            let arch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return arch.isEmpty ? nil : arch
        } catch {
            Log.warn("docker", "could not inspect \(reference): \(error.localizedDescription)")
            return nil
        }
    }

    /// Local image names, minus `reference` when it was baked for another
    /// architecture — such an image can't be the incremental base of a bake
    /// for `platform` (Docker would try to pull the missing variant).
    public func localImageNames(reusing reference: String, for platform: LinuxPlatform) async -> [String] {
        let names = await localImageNames()
        guard let arch = await imageArchitecture(of: reference), arch != platform.dockerArchitecture else {
            return names
        }
        return names.filter { $0 != reference && !$0.hasPrefix("\(reference):") }
    }

    /// Local list of image references (for the checklist's image-present
    /// row and the doctor).
    public func localImageNames() async -> [String] {
        await cli.localImageNames()
    }

    /// Disk usage of every local image, in whole GB — the shared inventory's
    /// size column and per-runtime total. Empty when the CLI can't say: the
    /// rows then read "—", never a wrong number.
    public func localImageSizes() async -> [String: Int] {
        await cli.localImageSizes(
            arguments: ["images", "--format", "{{.Repository}}:{{.Tag}}\t{{.Size}}"], parse: Self.parseImageSizes)
    }

    /// `docker images` rows (`<repo>:<tag>\t<size>`) as whole GB. Pure so
    /// tests pin the unit handling.
    static func parseImageSizes(_ text: String) -> [String: Int] {
        var sizes: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let size = gigabytes(from: String(parts[1])) else { continue }
            let name = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            sizes[name] = size
        }
        return sizes
    }

    /// A human byte count (`4.18GB`, `700MB`, `1.22kB`) in whole GB.
    static func gigabytes(from human: String) -> Int? {
        let text = human.trimmingCharacters(in: .whitespaces)
        var digits = ""
        var index = text.startIndex
        while index < text.endIndex, text[index].isNumber || text[index] == "." {
            digits.append(text[index])
            index = text.index(after: index)
        }
        guard !digits.isEmpty, let value = Double(digits) else { return nil }
        let unit = String(text[index...]).trimmingCharacters(in: .whitespaces).lowercased()
        let scale: Double
        switch unit {
        case "b": scale = 1
        case "kb", "kib": scale = 1_000
        case "mb", "mib": scale = 1_000_000
        case "gb", "gib": scale = 1_000_000_000
        case "tb", "tib": scale = 1_000_000_000_000
        default: return nil
        }
        return LinuxContainerCLI.wholeGigabytes(bytes: value * scale)
    }

    /// Removes one local image (`docker image rm`); an image that is already
    /// gone is success.
    public func deleteImage(named name: String) async throws {
        try await cli.deleteImage(name)
    }

    func run(_ argv: [String], timeout: TimeInterval = 120) async throws -> ShellResult {
        try await shell.run(argv, cwd: nil, timeout: timeout)
    }
}
