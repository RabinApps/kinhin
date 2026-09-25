import Foundation

/// Bakes the runner agents into a Linux OCI image for the Apple-container
/// runtime (see `LinuxImageBaker` for the shared pipeline). `container` has no
/// commit, so the scratch container's filesystem is captured with
/// `container build` from a one-line Dockerfile.
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
            commit: { shell, scratch, target in
                let workdir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("kinhin-container-build-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
                defer {
                    bestEffort("container-image", "removing build context") {
                        try FileManager.default.removeItem(at: workdir)
                    }
                }
                try "FROM \(scratch)\n".write(
                    to: workdir.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
                let build = try await shell.run([binary, "build", "--tag", target, workdir.path])
                guard build.succeeded else {
                    throw ImageError.containerProvisioningFailed(
                        "container build failed: \(String(build.stderr.prefix(500)))")
                }
            }
        )
        return try await LinuxImageBaker(shell: shell, backend: backend).prepare(options, versions: versions)
    }
}
