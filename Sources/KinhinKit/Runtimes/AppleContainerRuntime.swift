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
    /// Linux image baked with the runner agents (`kinhin image prepare`).
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

    public init(
        shell: ShellRunning = Shell(),
        image: String = "kinhin-ci-linux",
        cpus: Int = 4,
        memoryGB: Int = 8,
        binPath: String? = nil,
        exists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
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

    /// The shared container-CLI driver in Apple `container`'s dialect.
    var cli: LinuxContainerCLI {
        LinuxContainerCLI(
            shell: shell, bin: bin,
            dialect: .init(
                tag: "container", listVerb: "list", removeVerb: "delete",
                listNameArguments: ["--quiet"], imageListArguments: ["image", "list", "--quiet"],
                imageRemoveArguments: ["image", "delete"], runFlags: [],
                shapeNote: nil),
            image: image, cpus: cpus, memoryBytes: memoryBytes)
    }

    // MARK: - Health

    public func health() async -> RuntimeHealth {
        let resolved = binPath ?? Paths.findExecutable(named: "container")
        guard let resolved, exists(resolved) else {
            return .missing(
                tool: "apple container",
                fix: "brew install container && container system start"
            )
        }
        // The CLI exists; require the host API service to be running
        // (every command fails opaquely without it).
        do {
            if try await run([resolved, "system", "status"]).succeeded { return .ready }
        } catch {
            Log.warn("container", "system status probe failed: \(error.localizedDescription)")
        }
        return .broken("the container system service is not running — start it with: container system start")
    }

    // MARK: - Lifecycle (the shared container CLI)

    public func provision(id: String, route: RepoRoute) async throws {
        try await cli.provision(id: id, route: route)
    }

    /// The bootstrap script (same forge scripts the Docker runtime uses —
    /// Linux agent paths), run inside the container via `container exec`.
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

    /// Ids of all known containers (running + stopped) — the recovery path
    /// enumerates instances through the runtime, no per-runtime branch.
    public func existingInstanceIDs() async throws -> [String] {
        try await cli.containerIDs(all: true)
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
        do {
            let result = try await run([bin, "image", "list", "--format", "json"])
            guard result.succeeded else { return [:] }
            return Self.parseImageSizes(result.stdout)
        } catch {
            Log.warn("container", "could not list image sizes: \(error.localizedDescription)")
            return [:]
        }
    }

    /// `container image list --format json` as whole GB: each entry's
    /// `variants[].size` (bytes — the FULL SIZE column) summed is the local
    /// disk the image occupies. Keyed by every name form the `-q` listing
    /// may print (`alpine:3.20` vs the JSON's fully qualified
    /// `docker.io/library/alpine:3.20`). Pure so tests pin the parsing.
    static func parseImageSizes(_ text: String) -> [String: Int] {
        guard let data = text.data(using: .utf8),
            let images = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [:] }
        var sizes: [String: Int] = [:]
        for image in images {
            guard let configuration = image["configuration"] as? [String: Any],
                let name = configuration["name"] as? String
            else { continue }
            let bytes = ((image["variants"] as? [[String: Any]]) ?? [])
                .compactMap { $0["size"] as? Int }
                .reduce(0, +)
            guard bytes > 0 else { continue }
            let gigabytes = max(1, Int((Double(bytes) / 1_000_000_000).rounded()))
            for form in nameForms(of: name) { sizes[form] = gigabytes }
        }
        return sizes
    }

    /// The name forms one image can be listed under: the JSON's fully
    /// qualified reference plus what `container image list -q` prints for
    /// it (registry — and then the default `library/` — prefix dropped).
    static func nameForms(of reference: String) -> [String] {
        var forms = [reference]
        var path = reference.split(separator: "/")
        guard path.count > 1 else { return forms }
        let first = path[0]
        if first.contains(".") || first.contains(":") || first == "localhost" {
            path.removeFirst()
            forms.append(path.joined(separator: "/"))
        }
        if path.count > 1, path[0] == "library" {
            path.removeFirst()
            forms.append(path.joined(separator: "/"))
        }
        return forms
    }

    /// Removes one local image (`container image delete`); an image that is
    /// already gone is success.
    public func deleteImage(named name: String) async throws {
        try await cli.deleteImage(name)
    }

    func run(_ argv: [String], timeout: TimeInterval = 120) async throws -> ShellResult {
        try await shell.run(argv, cwd: nil, timeout: timeout)
    }
}

enum RuntimeWatchError: LocalizedError {
    case registrationFailed(vm: String, stderr: String)
    case registrationTimeout(vm: String)

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let vm, let stderr):
            return "runner registration failed in \(vm): \(stderr.prefix(300))"
        case .registrationTimeout(let vm):
            return "runner in \(vm) did not start/register within the boot timeout"
        }
    }
}
