import Foundation

/// Bakes the runner agents into a Linux OCI image for the Apple-container
/// runtime. The install scripts (shared with `LinuxImageBaker`) run as `RUN`
/// steps of a `FROM <base>` build, so only the new layers are written, the base
/// layers are shared, and the base's image config (`ENV`, `WORKDIR`, ...) is kept.
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

    private static let logTag = "container-image"
    /// Directory of the build context holding the scripts, bind-mounted into the `RUN` steps so they leave no layer.
    private static let scriptsDir = "bake"
    private static let installScript = "install.sh"
    private static let toolchainsScript = "toolchains.sh"
    private static let guestScriptsDir = "/kinhin-bake"
    /// Printed by the base-image check; how a failed build is told apart from a failed install.
    private static let notDebianMarker = "kinhin: base image has no apt-get"

    /// The Dockerfile for one bake. `RUN` steps use exec form so the scripts run
    /// under `bash -l`, the login shell the scratch-container bake used.
    static func dockerfile(image: String, hasToolchains: Bool) -> String {
        func run(_ script: String) -> String {
            "RUN --mount=type=bind,source=\(scriptsDir),target=\(guestScriptsDir) "
                + "[\"/bin/bash\", \"-l\", \"\(guestScriptsDir)/\(script)\"]"
        }
        var lines = [
            "FROM \(image)",
            // The scripts assume root with no inherited entrypoint: kinhin starts containers
            // with its own command, and a base `ENTRYPOINT` would be prepended to it.
            "USER root",
            "ENTRYPOINT []",
            // POSIX sh, not bash: minimal non-Debian images (Alpine) have no bash, and this
            // check should be what rejects them, clearly.
            // printf's format keeps the marker out of the echoed command, so only the step's output matches it.
            "RUN command -v apt-get >/dev/null || { printf 'kinhin: base image has no %s\\n' apt-get >&2; exit 1; }",
            run(installScript),
        ]
        if hasToolchains { lines.append(run(toolchainsScript)) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Testable core with injected versions.
    public func prepare(_ options: Options, versions: RunnerVersionResolver.Versions) async throws -> String {
        let tag = Self.logTag
        try Task.checkCancellation()
        // Token-gated provisioning: identical policy to the VM path.
        let selection = try AgentSelection(override: options.storedTokens)
        let install = try LinuxImageBaker.installScript(options, selection: selection, versions: versions, tag: tag)
        let toolchains = options.toolchains.map { LinuxImageBaker.managedToolchainsScript($0, tag: tag) }

        // `/var` is a symlink to `/private/var`, and `container build` before 1.5.0 silently drops
        // context files under a symlinked path.
        let context = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-container-build-\(UUID().uuidString)").resolvingSymlinksInPath()
        let scripts = context.appendingPathComponent(Self.scriptsDir)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer {
            bestEffort(tag, "removing build context") { try FileManager.default.removeItem(at: context) }
        }
        try Self.dockerfile(image: options.image, hasToolchains: toolchains != nil).write(
            to: context.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        try install.write(
            to: scripts.appendingPathComponent(Self.installScript), atomically: true, encoding: .utf8)
        if let toolchains {
            try toolchains.write(
                to: scripts.appendingPathComponent(Self.toolchainsScript), atomically: true, encoding: .utf8)
        }

        let binary = Paths.findExecutable(named: "container") ?? "/usr/local/bin/container"
        // A non-native image is tagged for its platform, so `container run --platform` finds it.
        var argv = [binary, "build", "--tag", options.target]
        if options.platform != .arm64 { Log.warn(tag, LinuxPlatform.containerEmulationNotice) }
        argv += AppleContainerRuntime.platformRunFlags(options.platform) + [context.path]
        let timeout: TimeInterval = 1800 + (toolchains == nil ? 0 : options.toolchainTimeout)

        Log.info(tag, "building \(options.target) as layers on \(options.image)")
        var build = try await shell.run(argv, cwd: nil, timeout: timeout)
        // A fresh `container` install has no Linux kernel until one is downloaded; `system start`
        // can be running and still lack it. Install it and build once more.
        if !build.succeeded, build.stderr.contains("kernel not configured") {
            do {
                try await AppleContainerRuntime.installKernel(shell: shell, binary: binary)
                build = try await shell.run(argv, cwd: nil, timeout: timeout)
            } catch {
                Log.warn(tag, "kernel install failed: \(error.localizedDescription)")
            }
        }
        guard build.succeeded else {
            if output(of: build, contains: Self.notDebianMarker) {
                throw ImageError.containerProvisioningFailed(
                    "'\(options.image)' isn't Debian/Ubuntu-based — kinhin's install scripts need apt-get. Pick a Debian or Ubuntu base image."
                )
            }
            if output(of: build, contains: "\(Self.guestScriptsDir)/\(Self.toolchainsScript)") {
                throw ImageError.containerProvisioningFailed(
                    "managed toolchain install failed: \(build.failureExcerpt)")
            }
            throw ImageError.containerProvisioningFailed("container build failed: \(build.failureExcerpt)")
        }
        // The previous image is only replaced by a successful build, so a failed or cancelled bake leaves it intact.
        Log.info(tag, "prepared container image '\(options.target)' is ready")
        return options.target
    }

    private func output(of result: ShellResult, contains text: String) -> Bool {
        result.stderr.contains(text) || result.stdout.contains(text)
    }
}
