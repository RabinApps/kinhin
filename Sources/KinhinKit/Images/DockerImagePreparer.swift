import Foundation

/// Bakes the runner agents into a Linux OCI image for the Docker runtime
/// (see `LinuxImageBaker` for the shared pipeline).
///
/// Unlike the Apple-container preparer (which must `container build` because
/// `container` has no commit), Docker's native `docker commit` keeps this a
/// simple bake with no temp build context.
public struct DockerImagePreparer {
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
        let binary = DockerRuntime.resolvedBinaryPath
        let backend = LinuxImageBaker.Backend(
            logTag: "docker-image",
            displayName: "docker",
            binary: binary,
            removeVerb: "rm",
            commit: { shell, scratch, target in
                let commit = try await shell.run([binary, "commit", scratch, target])
                guard commit.succeeded else {
                    throw ImageError.containerProvisioningFailed(
                        "docker commit failed: \(commit.failureExcerpt)")
                }
            }
        )
        return try await LinuxImageBaker(shell: shell, backend: backend).prepare(options, versions: versions)
    }
}
