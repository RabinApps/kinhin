import Foundation

/// Builds one video of a repository: checks the config exists, picks a runtime, makes sure the image is there, runs it.
public struct VideoRunner: Sendable {
    let shell: ShellRunning
    let process: VideoProcessRunning
    let environment: [String: String]
    let cpuCount: Int
    /// The `container` and `docker` binaries, resolved on this machine (nil = not installed). Injected for tests.
    let binaries: @Sendable (VideoRuntime) -> String?

    public init(
        shell: ShellRunning = Shell(), process: VideoProcessRunning = InheritedProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cpuCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        binaries: @escaping @Sendable (VideoRuntime) -> String? = VideoRunner.installedBinary
    ) {
        self.shell = shell
        self.process = process
        self.environment = environment
        self.cpuCount = cpuCount
        self.binaries = binaries
    }

    /// Where each runtime's CLI is installed (the same lookup the fleet's runtimes use).
    public static let installedBinary: @Sendable (VideoRuntime) -> String? = { runtime in
        switch runtime {
        case .appleContainer: return Paths.findExecutable(named: "container")
        case .docker: return Paths.findExecutable(named: "docker")
        }
    }

    /// The runtime to use: `preferred` if given (it must work), else Apple's `container` when its service is running,
    /// else Docker when its daemon answers.
    public func detectRuntime(preferred: VideoRuntime?) async throws -> (runtime: VideoRuntime, binary: String) {
        let candidates = preferred.map { [$0] } ?? VideoRuntime.allCases
        var problems: [String] = []
        for runtime in candidates {
            guard let binary = binaries(runtime) else {
                problems.append("\(runtime.rawValue) is not installed")
                continue
            }
            let probe =
                runtime == .appleContainer
                ? [binary, "system", "status"] : [binary, "info", "--format", "{{.ServerVersion}}"]
            // A probe that cannot launch is a "not running" answer like a failing one; cancellation propagates.
            if let result = try await probeResult(probe), result.succeeded {
                return (runtime, binary)
            }
            problems.append(
                runtime == .appleContainer
                    ? "the container system service is not running (container system start)"
                    : "the Docker daemon is not running")
        }
        // A probe cut short by cancellation reads as "not running"; report the cancellation instead.
        try Task.checkCancellation()
        if let preferred {
            throw VideoError.runtimeUnavailable(
                "\(preferred.rawValue) is not usable: \(problems.joined(separator: "; "))")
        }
        throw VideoError.noRuntime
    }

    /// The plan for `options` in `repo` without running anything (also what `--dry-run` style callers show).
    public func plan(
        options: VideoBuildOptions, repo: URL, runtime preferred: VideoRuntime?, image override: String?
    ) async throws -> VideoRunPlan {
        guard FileManager.default.fileExists(atPath: VideoProjects.directory(in: repo).path) else {
            throw VideoError.noVideosFolder(repo.path)
        }
        guard VideoProjects.file(named: options.project, in: repo) != nil else {
            throw VideoError.unknownProject(name: options.project, available: VideoProjects.list(in: repo))
        }
        // The mounts are `-v host:container` specs, so a colon in the path would be read as a separator.
        if repo.path.contains(":") { throw VideoError.unmountablePath(repo.path) }
        let (runtime, binary) = try await detectRuntime(preferred: preferred)
        return VideoRunPlan.make(
            options: options, runtime: runtime, binary: binary,
            image: VideoImage.reference(override: override, environment: environment), repo: repo, cpuCount: cpuCount)
    }

    /// Builds the video; returns the pipeline's exit code (0 = done, the video is in `plan.outputDirectory`).
    public func build(plan: VideoRunPlan) async throws -> Int32 {
        try FileManager.default.createDirectory(at: plan.outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plan.cacheDirectory, withIntermediateDirectories: true)
        try await ensureImage(image: plan.image, inspect: plan.inspect, pull: plan.pull)
        return try await process.runInteractive(plan.run)
    }

    /// Checks one video of `repo` (`project`), or every video when it is nil, without rendering: returns the check's exit
    /// code (0 = every checked video can be built, 1 = a video has a problem, which the output says).
    public func validate(
        repo: URL, project: String?, runtime preferred: VideoRuntime?, image override: String?
    ) async throws -> Int32 {
        guard FileManager.default.fileExists(atPath: VideoProjects.directory(in: repo).path) else {
            throw VideoError.noVideosFolder(repo.path)
        }
        if let project, VideoProjects.file(named: project, in: repo) == nil {
            throw VideoError.unknownProject(name: project, available: VideoProjects.list(in: repo))
        }
        if repo.path.contains(":") { throw VideoError.unmountablePath(repo.path) }
        let (_, binary) = try await detectRuntime(preferred: preferred)
        let image = VideoImage.reference(override: override, environment: environment)
        try await ensureImage(
            image: image, inspect: [binary, "image", "inspect", image], pull: [binary, "image", "pull", image])
        return try await process.runInteractive(
            VideoRunPlan.validation(binary: binary, image: image, repo: repo, project: project))
    }

    /// A probe's result, nil when it could not even launch (a "no" for the
    /// caller). Cancellation is not a "no": it propagates.
    private func probeResult(_ argv: [String], timeout: TimeInterval = 20) async throws -> ShellResult? {
        do {
            return try await shell.run(argv, cwd: nil, timeout: timeout)
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            return nil
        }
    }

    /// Pulls the image when it is not on this machine yet (the first build downloads about a gigabyte).
    func ensureImage(image: String, inspect: [String], pull: [String]) async throws {
        if let present = try await probeResult(inspect, timeout: 30), present.succeeded { return }
        FileHandle.standardError.write(Data("==> pulling \(image) (first build only)\n".utf8))
        let code: Int32
        do {
            code = try await process.runInteractive(pull)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VideoError.imageUnavailable(image: image, reason: error.localizedDescription)
        }
        if code != 0 { throw VideoError.imageUnavailable(image: image, reason: "pull exited \(code)") }
    }
}
