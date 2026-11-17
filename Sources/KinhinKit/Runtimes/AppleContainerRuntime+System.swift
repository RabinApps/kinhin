import Foundation

// AppleContainerRuntime — the `container` system service and its Linux
// kernel: what must be in place before any container can run.
extension AppleContainerRuntime {
    // MARK: - System service

    /// Makes the container system usable: its service running, and a Linux
    /// kernel installed (a system started by hand may lack one). Healing, setup
    /// and image builds all start it through here, so with `container_app_root:`
    /// set every start passes `--app-root`, after the preflight has checked that
    /// volume: a start never falls back to the default app root.
    public static func startSystem(
        shell: ShellRunning = Shell(), appRoot: String? = StorageLocations.current.containerAppRoot,
        preflight: StoragePreflight = .live
    ) async throws {
        if let appRoot, let problem = preflight.problem(.containerAppRoot, path: appRoot) {
            Log.error("container", problem.localizedDescription)
            throw problem
        }
        if !(await AppleContainerRuntime(shell: shell).health()).isReady {
            let result = try await shell.run(
                startArguments(binary: resolvedBinaryPath, appRoot: appRoot), cwd: nil, timeout: 120)
            guard result.succeeded else {
                throw ContainerManagerError.commandFailed(what: "starting the container system", stderr: result.stderr)
            }
        } else if let appRoot {
            try await requireRunningAppRoot(appRoot, shell: shell)
        }
        try await ensureKernel(
            shell: shell, binary: resolvedBinaryPath, directory: kernels(underAppRoot: appRoot))
    }

    /// A service that is already running keeps the app root it was started with: `container system start` does not
    /// move it, and the kernel install writes under it. When that root is not `container_app_root:`, every image,
    /// container and kernel would land in the old root, so stop here. kinhin does not stop the service itself, since
    /// that stops every container (busy runners and the Docker Hub cache with them). A status kinhin cannot read, or
    /// one without the root (an older CLI), is accepted as it was before.
    static func requireRunningAppRoot(_ appRoot: String, shell: ShellRunning) async throws {
        let result: ShellResult
        do {
            result = try await shell.run(
                [resolvedBinaryPath, "system", "status", "--format", "json"], cwd: nil, timeout: 30)
        } catch {
            Log.warn("container", "could not read the container system's app root: \(error.localizedDescription)")
            return
        }
        guard result.succeeded, let running = runningAppRoot(statusJSON: result.stdout) else { return }
        guard !StoragePreflight.sameDirectory(running, appRoot) else { return }
        let problem = StorageProblem(
            location: .containerAppRoot, path: appRoot,
            problem: "the container system is running with the app root \(running)",
            fix: "run `container system stop` once no runner is busy (it stops every container); kinhin then starts "
                + "it on \(appRoot)")
        Log.error("container", problem.localizedDescription)
        throw problem
    }

    /// `paths.appRoot` from `container system status --format json`; nil when it is not there.
    static func runningAppRoot(statusJSON: String) -> String? {
        // Output that is not the expected JSON has no root to compare; the start goes on as before.
        guard let object = try? JSONSerialization.jsonObject(with: Data(statusJSON.utf8)) as? [String: Any],
            let paths = object["paths"] as? [String: Any], let root = paths["appRoot"] as? String, !root.isEmpty
        else { return nil }
        return root
    }

    /// The `container system start` argv. `--enable-kernel-install`: without it
    /// the CLI asks a question and fails ("failed to read user input") when run
    /// without a terminal.
    static func startArguments(binary: String, appRoot: String?) -> [String] {
        [binary, "system", "start"] + (appRoot.map { ["--app-root", $0] } ?? []) + ["--enable-kernel-install"]
    }

    // MARK: - Linux kernel

    /// Where the `container` CLI keeps installed kernels: `kernels/` under the
    /// app root (`container_app_root:`, else the CLI's default).
    public static var kernelDirectory: URL {
        kernels(underAppRoot: StorageLocations.current.containerAppRoot)
    }

    static func kernels(underAppRoot appRoot: String?) -> URL {
        let root =
            appRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Paths.userLibrarySubdirectory(.applicationSupportDirectory, fallback: "Library/Application Support")
            .appendingPathComponent("com.apple.container", isDirectory: true)
        return root.appendingPathComponent("kernels", isDirectory: true)
    }

    /// Whether a default Linux kernel is installed. `container system start`
    /// can be running without one (the install is an opt-in prompt), and then
    /// every `container run` fails with "default kernel not configured".
    public static func hasInstalledKernel(in directory: URL = kernelDirectory) -> Bool {
        // An absent (or unreadable) kernels dir means none are installed.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return entries.contains { !$0.hasPrefix(".") }
    }

    /// Downloads and installs the recommended kernel (`container system kernel
    /// set --recommended`; a few hundred MB, so allow several minutes).
    public static func installKernel(shell: ShellRunning = Shell(), binary: String = resolvedBinaryPath) async throws {
        Log.info("container", "installing the recommended Linux kernel")
        let result = try await shell.run(
            [binary, "system", "kernel", "set", "--recommended"], cwd: nil, timeout: 900)
        guard result.succeeded else {
            let reason = String(result.stderr.split(whereSeparator: \.isNewline).last ?? "no error output")
            throw ContainerManagerError.commandFailed(what: "installing the container Linux kernel", stderr: reason)
        }
    }

    /// Stops and deletes the image builder, freeing its build cache (it can reach
    /// 100 GB after baking a large base image). The next `container build`
    /// starts a fresh builder. A builder that is not running, or does not
    /// exist, is not an error.
    public static func deleteBuilder(shell: ShellRunning = Shell(), binary: String = resolvedBinaryPath) async throws {
        Log.info("container", "stopping and deleting the container builder")
        _ = try await shell.run([binary, "builder", "stop"], cwd: nil, timeout: 120)
        let result = try await shell.run([binary, "builder", "delete"], cwd: nil, timeout: 300)
        guard result.succeeded || result.stderr.localizedCaseInsensitiveContains("not found") else {
            let reason = String(result.stderr.split(whereSeparator: \.isNewline).last ?? "no error output")
            throw ContainerManagerError.commandFailed(what: "deleting the container builder", stderr: reason)
        }
    }

    /// Installs the kernel only when none is present.
    public static func ensureKernel(
        shell: ShellRunning = Shell(), binary: String = resolvedBinaryPath, directory: URL = kernelDirectory
    ) async throws {
        guard !hasInstalledKernel(in: directory) else { return }
        try await installKernel(shell: shell, binary: binary)
    }
}
