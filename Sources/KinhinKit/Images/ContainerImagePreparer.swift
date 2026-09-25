import Foundation

/// Bakes the runner agents into a Linux OCI image for the Apple-container
/// runtime (see `LinuxImageBaker` for the shared pipeline). `container` has no
/// commit, so the scratch container's filesystem is exported to a tar and
/// rebuilt into the target image with `container build` (FROM scratch).
public struct ContainerImagePreparer {
    public typealias Options = LinuxImageOptions

    let shell: ShellRunning

    public init(shell: ShellRunning) {
        self.shell = shell
    }

    /// Resolve the runner-agent versions from the vendors' feeds (pinned
    /// fallback offline), then run the bake.
    @discardableResult
    public func prepare(_ options: Options) async throws -> String {
        let versions = await RunnerVersionResolver().resolve()
        return try await prepare(options, versions: versions)
    }

    /// Back-compat entry without toolchains.
    @discardableResult
    public func prepare(image: String, target: String, user: String = "admin") async throws -> String {
        try await prepare(.init(image: image, target: target, user: user))
    }

    /// Testable core with injected versions.
    public func prepare(_ options: Options, versions: RunnerVersionResolver.Versions) async throws -> String {
        let binary = Paths.findExecutable(named: "container") ?? "/usr/local/bin/container"
        let backend = LinuxImageBaker.Backend(
            logTag: "container-image",
            displayName: "container",
            binary: binary,
            removeVerb: "delete",
            recoverStartFailure: { shell, stderr in
                // A fresh `container` install has no Linux kernel until one is
                // downloaded; `system start` can be running and still lack it.
                guard stderr.contains("kernel not configured") else { return false }
                do {
                    try await AppleContainerRuntime.installKernel(shell: shell, binary: binary)
                    return true
                } catch {
                    Log.warn("container-image", "kernel install failed: \(error.localizedDescription)")
                    return false
                }
            },
            commit: { shell, scratch, target in
                // `container` has no `commit`, and a Dockerfile cannot start
                // FROM a container: export the scratch container's filesystem
                // and rebuild it as a single layer over `scratch`.
                let workdir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("kinhin-container-build-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
                defer {
                    bestEffort("container-image", "removing build context") {
                        try FileManager.default.removeItem(at: workdir)
                    }
                }
                let rootfs = workdir.appendingPathComponent("rootfs.tar")
                let exported = try await shell.run(
                    [binary, "export", "--output", rootfs.path, scratch], cwd: nil, timeout: 1800)
                guard exported.succeeded else {
                    throw ImageError.containerProvisioningFailed(
                        "container export failed: \(exported.failureExcerpt)")
                }
                try "FROM scratch\nADD rootfs.tar /\n".write(
                    to: workdir.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
                let build = try await shell.run(
                    [binary, "build", "--tag", target, workdir.path], cwd: nil, timeout: 1800)
                guard build.succeeded else {
                    throw ImageError.containerProvisioningFailed(
                        "container build failed: \(build.failureExcerpt)")
                }
            }
        )
        return try await LinuxImageBaker(shell: shell, backend: backend).prepare(options, versions: versions)
    }
}
