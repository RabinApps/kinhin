import Foundation

/// The container runtimes a video build can use.
public enum VideoRuntime: String, CaseIterable, Sendable {
    case appleContainer = "container"
    case docker
}

/// Everything `kinhin video build` asks for.
public struct VideoBuildOptions: Equatable, Sendable {
    public var project: String
    public var theme: String?
    public var format: String?
    /// `on`, `off` or `all`.
    public var captions: String?
    public var captionStyle: String?
    /// A catalog track, a file in the repository, or `off`.
    public var music: String?
    public var fast = false

    public init(project: String) { self.project = project }
}

/// The exact commands of one build, as data: which runtime, which image, the mounts and the arguments the pipeline gets.
/// Pure, so tests can pin it.
public struct VideoRunPlan: Equatable, Sendable {
    /// The pipeline's entry point inside the image (an absolute path: Apple's `container` does not resolve a relative one).
    public static let entryScript = "/work/scripts/container-build.sh"

    public let runtime: VideoRuntime
    public let image: String
    public let inspect: [String]
    public let pull: [String]
    public let run: [String]
    /// Where the finished video lands, and the render cache, both inside `<repo>/.kinhin/videos/`.
    public let outputDirectory: URL
    public let cacheDirectory: URL

    public static func make(
        options: VideoBuildOptions, runtime: VideoRuntime, binary: String, image: String, repo: URL,
        cpuCount: Int = ProcessInfo.processInfo.activeProcessorCount, memory: String? = nil
    ) -> VideoRunPlan {
        let videos = VideoProjects.directory(in: repo)
        let output = videos.appendingPathComponent("out", isDirectory: true)
        let cache = videos.appendingPathComponent(".cache", isDirectory: true)

        // Four CPUs unless the machine has fewer (Docker refuses a count above the machine's).
        let cpus = String(max(1, min(4, cpuCount)))
        let size: [String]
        switch runtime {
        case .appleContainer: size = ["-c", cpus, "-m", memory ?? "6G"]
        case .docker: size = ["--cpus", cpus, "--memory", memory ?? "6g"]
        }

        var entry = [VideoRunPlan.entryScript, "--project", options.project]
        func add(_ flag: String, _ value: String?) {
            if let value, !value.isEmpty { entry += [flag, value] }
        }
        add("--theme", options.theme)
        add("--format", options.format)
        add("--captions", options.captions)
        add("--caption-style", options.captionStyle)
        add("--music", options.music)
        if options.fast { entry.append("--fast") }

        let run =
            [binary, "run", "--rm"] + size + [
                "-v", "\(repo.path):/project:ro",
                "-v", "\(output.path):/work/out",
                "-v", "\(cache.path):/work/raw",
                image,
            ] + entry
        return VideoRunPlan(
            runtime: runtime, image: image, inspect: [binary, "image", "inspect", image],
            pull: [binary, "image", "pull", image], run: run, outputDirectory: output, cacheDirectory: cache)
    }
}
