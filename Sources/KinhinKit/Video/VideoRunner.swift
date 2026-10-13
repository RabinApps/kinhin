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
            if let result = try? await shell.run(probe, cwd: nil, timeout: 20), result.succeeded {
                return (runtime, binary)
            }
            problems.append(
                runtime == .appleContainer
                    ? "the container system service is not running (container system start)"
                    : "the Docker daemon is not running")
        }
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
        let (runtime, binary) = try await detectRuntime(preferred: preferred)
        return VideoRunPlan.make(
            options: options, runtime: runtime, binary: binary,
            image: VideoImage.reference(override: override, environment: environment), repo: repo, cpuCount: cpuCount)
    }

    /// Builds the video; returns the pipeline's exit code (0 = done, the video is in `plan.outputDirectory`).
    public func build(plan: VideoRunPlan) async throws -> Int32 {
        try FileManager.default.createDirectory(at: plan.outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plan.cacheDirectory, withIntermediateDirectories: true)
        try await ensureImage(plan)
        return try await process.runInteractive(plan.run)
    }

    /// Pulls the image when it is not on this machine yet (the first build downloads about a gigabyte).
    func ensureImage(_ plan: VideoRunPlan) async throws {
        if let present = try? await shell.run(plan.inspect, cwd: nil, timeout: 30), present.succeeded { return }
        FileHandle.standardError.write(Data("==> pulling \(plan.image) (first build only)\n".utf8))
        let code: Int32
        do {
            code = try await process.runInteractive(plan.pull)
        } catch {
            throw VideoError.imageUnavailable(image: plan.image, reason: error.localizedDescription)
        }
        if code != 0 { throw VideoError.imageUnavailable(image: plan.image, reason: "pull exited \(code)") }
    }
}
