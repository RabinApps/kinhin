import Foundation

// AppleContainerRuntime — the `container` system service and its Linux
// kernel: what must be in place before any container can run.
extension AppleContainerRuntime {
    // MARK: - System service

    /// Makes the container system usable: its service running, and a Linux
    /// kernel installed (a system started by hand may lack one).
    public static func startSystem(shell: ShellRunning = Shell()) async throws {
        if !(await AppleContainerRuntime(shell: shell).health()).isReady {
            let result = try await shell.run(
                // --enable-kernel-install: without it the CLI asks a question and
                // fails ("failed to read user input") when run without a terminal.
                [resolvedBinaryPath, "system", "start", "--enable-kernel-install"],
                cwd: nil, timeout: 120
            )
            guard result.succeeded else {
                throw ContainerManagerError.commandFailed(what: "starting the container system", stderr: result.stderr)
            }
        }
        try await ensureKernel(shell: shell)
    }

    // MARK: - Linux kernel

    /// Where the `container` CLI keeps installed kernels (its default app root).
    public static var kernelDirectory: URL {
        Paths.userLibrarySubdirectory(.applicationSupportDirectory, fallback: "Library/Application Support")
            .appendingPathComponent("com.apple.container/kernels", isDirectory: true)
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

    /// Installs the kernel only when none is present.
    public static func ensureKernel(shell: ShellRunning = Shell(), binary: String = resolvedBinaryPath) async throws {
        guard !hasInstalledKernel() else { return }
        try await installKernel(shell: shell, binary: binary)
    }
}
